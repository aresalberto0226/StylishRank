"use strict";
// StylishRank - PBZModLoader mod (Devil May Cry 5 style rank display)
//
// Real combat scoring: attacks, deflects, hits taken, executions.
//
// Combat signals (confirmed readable in-game):
//   anim.GameplayTag_IsInCombat  - in combat (bool)
//   anim.GameplayTag_IsStance    - blocking stance (bool)
//   NOTE: IsMelee / IsDashing stay false while attacking/dodging - do not use.
//   Attacking is detected by the active montage name ("Attack"/"Skill")
//   plus anim.IsAnyMontagePlaying().
//   pawn.AttributeSetBase.Health.CurrentValue - health (float)
//   pawn["Deflect Component"].PerfectDodgeResultData.HitGameTime - last deflect time (float)
//   ...IsHit                    - true = the deflect/dodge still got hit (bool)
//
// Show/hide: one UImage lives in the viewport; visibility is toggled with
// Collapsed / HitTestInvisible. Opacity is never written (the badge is always
// fully opaque); the StylishAudio Lua mod only touches scale and tint to make
// the badge pulse with the music.

(function () {
    const TAG = "[StylishRank]";

    // ---- config ---------------------------------------------------------------
    const RANKS = ["D", "C", "B", "A", "S", "SS", "SSS"];
    // Minimum score for each rank (index-aligned with RANKS).
    const RANK_MIN = [10, 30, 60, 90, 120, 150, 200];
    const INITIAL_RANK = "D";
    const MARGIN = 44;
    const SLOT_W = 200;
    const SLOT_H = 200;
    const Z_ORDER = 1000000;   // must be above the game HUD (loader notifier uses this too)
    const RETRY_MS = 1000;
    const MAX_RETRIES = 300;
    // Files exchanged with the StylishAudio UE4SS mod (see audioDir()):
    //   cmd.txt       - "play <rank>" command for the sound service
    //   bgwidget.txt  - UObject name of the badge, so Lua can animate it
    // PuerTS can only WRITE files; the Lua mod reads them.

    // ---- file exchange with the StylishAudio mod ------------------------------
    // <game>/platform/steam/ue4ss/Mods/StylishAudio/audio/
    // The game root is derived from any project path the engine exposes
    // (GetProjectDirectory / GetProjectSavedDirectory / ProjectContentDir /
    // ProjectSavedDir / ProjectDir) and every candidate is verified with
    // BlueprintPathsLibrary.DirectoryExists before use, so the mod works no
    // matter where the game is installed. If none of them verifies (some UE
    // versions hand out odd relative paths), fall back to the known install.
    const AUDIO_REL = "/platform/steam/ue4ss/Mods/StylishAudio/audio";
    const AUDIO_FALLBACK = "D:/SteamLibrary/steamapps/common/PBZ" + AUDIO_REL;

    let audioDirCache = null;

    function isAbsPath(s) { return /^[A-Za-z]:\//.test(s) || /^\/\//.test(s); }

    // ".../<game>/ProjectPBZ[/Saved|/Content|...]" -> ".../<game>"
    function gameRootFrom(p) {
        if (!p) return "";
        const d = String(p).replace(/\\/g, "/").replace(/\/+$/, "");
        if (!d) return "";
        const marker = d.toLowerCase().indexOf("/projectpbz");
        if (marker > 0) return d.slice(0, marker);
        const slash = d.lastIndexOf("/");
        return slash > 0 ? d.slice(0, slash) : "";
    }

    function audioDir() {
        if (audioDirCache !== null) return audioDirCache;
        audioDirCache = "";

        const paths = UE.BlueprintPathsLibrary;
        const lib = UE.KismetSystemLibrary;
        const candidates = [];

        function add(label, value) {
            let s = (value === null || value === undefined) ? "" : String(value);
            if (!s) return;
            // Only resolve relative input; an absolute path is kept verbatim.
            if (!isAbsPath(s) && paths && typeof paths.ConvertRelativePathToFull === "function") {
                try { s = String(paths.ConvertRelativePathToFull(s, "") || s); } catch (e) {}
            }
            const root = gameRootFrom(s);
            if (root) candidates.push({ label: label, root: root });
        }

        try {
            if (lib && typeof lib.GetProjectDirectory === "function") add("GetProjectDirectory", lib.GetProjectDirectory());
            if (lib && typeof lib.GetProjectSavedDirectory === "function") add("GetProjectSavedDirectory", lib.GetProjectSavedDirectory());
            if (paths && typeof paths.ProjectContentDir === "function") add("ProjectContentDir", paths.ProjectContentDir());
            if (paths && typeof paths.ProjectSavedDir === "function") add("ProjectSavedDir", paths.ProjectSavedDir());
            if (paths && typeof paths.ProjectDir === "function") add("ProjectDir", paths.ProjectDir());
            if (lib && typeof lib.GetProjectContentDirectory === "function") add("GetProjectContentDirectory", lib.GetProjectContentDirectory());
        } catch (e) { warn("audio dir candidates: " + String(e)); }

        const seen = {};
        for (let i = 0; i < candidates.length; i++) {
            const c = candidates[i];
            if (seen[c.root]) continue;
            seen[c.root] = true;
            const full = c.root + AUDIO_REL;
            let ok = false;
            try {
                ok = !!(paths && typeof paths.DirectoryExists === "function" && paths.DirectoryExists(full) === true);
            } catch (e) { ok = false; }
            log("audio dir candidate " + c.label + ": " + full + " exists=" + ok);
            if (ok) {
                audioDirCache = full;
                log("audio dir: " + full);
                return full;
            }
        }

        warn("audio dir: no candidate verified, using fallback");
        audioDirCache = AUDIO_FALLBACK;
        log("audio dir: " + audioDirCache);
        return audioDirCache;
    }
    function audioFile(name) {
        const d = audioDir();
        return d ? d + "/" + name : null;
    }

    // ---- scoring --------------------------------------------------------------
    const POLL_MS = 250;
    const SCORE_MAX = 220;
    const SCORE_MELEE = 2;
    const SCORE_DEFLECT = 10;
    const SCORE_DEFLECT_FAIL = 15;
    const SCORE_DAMAGE = 10;
    const SCORE_EXECUTION = 10;   // bonus per execution finisher (处决)
    // Passive play penalty: in combat but not attacking for longer than the
    // grace period loses style continuously (see updateRank).
    const IDLE_GRACE_MS = 2000;
    const SCORE_IDLE_DRAIN = 20;  // points lost per second while idling
    // Attack score accrues per REAL TIME, not per tick, so the score curve does
    // not depend on timer jitter.
    const SCORE_WINDOW_MS = 250;

    // ---- state ----------------------------------------------------------------
    let widget = null;
    let viewport = null;
    let animTimer = null;
    let retryTimer = null;
    let pollTimer = null;
    let retryCount = 0;
    let prevMissing = undefined;
    const readyLog = { gi: false, pc: false, viewport: false };
    let currentRank = INITIAL_RANK;
    let score = 0;
    let prevHealth = null;
    let prevDeflectTime = null;
    let created = false;
    // The widget is created with the rank text already visible (non-empty), so
    // its "shown" state must start true; otherwise hideRank() never fires.
    let shown = true;
    let readReported = false;
    let lastDebugLog = 0;
    const textureCache = {};
    let lastScoreTime = null;   // Date.now() of the last scoring tick
    let lastActionTime = null;  // Date.now() of the last attack / deflect
    let lastExecName = null;    // execution montage already awarded (avoid re-award)
    let viewportW = 0;
    let viewportH = 0;
    let slotW = 0;
    let slotH = 0;
    let dSoundPlayed = false;    // avoid replaying D when score hovers at the gate

    const log = function (m) { console.error(TAG + " " + m); };
    const warn = function (m) { console.error(TAG + " " + m); };

    const UE = require("ue");
    const puerts = require("puerts");
    const rankImages = require("./rankImages");

    // ---- engine object lookups -----------------------------------------------
    function getGameInstance() {
        try { return puerts.argv.getByName("GameInstance") || null; }
        catch (e) { return null; }
    }
    function getPlayerController(gi) {
        try {
            const pc = UE.GameplayStatics.GetPlayerController(gi, 0);
            return (pc && UE.KismetSystemLibrary.IsValid(pc)) ? pc : null;
        } catch (e) { return null; }
    }
    function getViewport() {
        try {
            const vp = UE.SubsystemBlueprintLibrary.GetEngineSubsystem(
                UE.GameViewportSubsystem.StaticClass());
            return vp || null;
        } catch (e) { return null; }
    }

    function readViewportSize(pc) {
        const sx = puerts.$ref(0);
        const sy = puerts.$ref(0);
        pc.GetViewportSize(sx, sy);
        const scale = Math.max(0.01, UE.WidgetLayoutLibrary.GetViewportScale(pc));
        return { w: puerts.$unref(sx) / scale, h: puerts.$unref(sy) / scale };
    }

    // ---- combat state reading -------------------------------------------------
    function getPawn() {
        try {
            const gi = getGameInstance();
            if (!gi) return null;
            const pc = UE.GameplayStatics.GetPlayerController(gi, 0);
            if (!pc || !UE.KismetSystemLibrary.IsValid(pc)) return null;
            const pawn = pc.Pawn;
            return (pawn && UE.KismetSystemLibrary.IsValid(pawn)) ? pawn : null;
        } catch (e) { return null; }
    }

    function getAnim(pawn) {
        try {
            const mesh = pawn.Mesh;
            if (!mesh || !UE.KismetSystemLibrary.IsValid(mesh)) return null;
            return mesh.GetAnimInstance();
        } catch (e) { return null; }
    }

    function readFlag(obj, name) {
        try {
            const v = obj[name];
            if (v === true) return true;
            if (v === false) return false;
            return null;
        } catch (e) { return null; }
    }

    function readHealth(pawn) {
        try {
            const asb = pawn.AttributeSetBase;
            if (!asb || !UE.KismetSystemLibrary.IsValid(asb)) return null;
            const v = asb.Health.CurrentValue;
            return (typeof v === "number") ? v : null;
        } catch (e) { return null; }
    }

    function readDeflect(pawn) {
        try {
            const deflect = pawn["Deflect Component"];
            if (!deflect || !UE.KismetSystemLibrary.IsValid(deflect)) return null;
            const pdd = deflect.PerfectDodgeResultData;
            const t = pdd.HitGameTime;
            const isHit = pdd.IsHit;
            return { hitGameTime: (typeof t === "number") ? t : null, isHit: (isHit === true) };
        } catch (e) { return null; }
    }

    function readMontageName(anim) {
        try {
            const m = anim.GetCurrentActiveMontage();
            if (m && UE.KismetSystemLibrary.IsValid(m)) return String(m.GetName());
        } catch (e) {}
        return "none";
    }

    // base64 -> bytes (same hand-written decoder as PBZMapMarkers main.js)
    function b64bytes(s) {
        const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const val = new Uint8Array(128);
        for (let i = 0; i < 64; i++) val[A.charCodeAt(i)] = i;
        const c = s.replace(/[^A-Za-z0-9+/]/g, "");
        const out = new Uint8Array(Math.floor(c.length * 3 / 4));
        let o = 0;
        for (let i = 0; i + 1 < c.length; i += 4) {
            const n = (val[c.charCodeAt(i)] << 18) | (val[c.charCodeAt(i + 1)] << 12) |
                ((i + 2 < c.length ? val[c.charCodeAt(i + 2)] : 0) << 6) | (i + 3 < c.length ? val[c.charCodeAt(i + 3)] : 0);
            out[o++] = (n >> 16) & 255;
            if (i + 2 < c.length) out[o++] = (n >> 8) & 255;
            if (i + 3 < c.length) out[o++] = n & 255;
        }
        return out.subarray(0, o);
    }

    function getRankTexture(rank) {
        const cached = textureCache[rank];
        if (cached && cached.tex) return cached;
        textureCache[rank] = { tex: null, w: 0, h: 0 };
        try {
            const data = rankImages[rank];
            if (!data || !data.b64) return textureCache[rank];
            // Use a FRESH world context each time; the PlayerController cached at
            // createWidget time can become invalid later (level transition etc).
            const ctx = getPawn() || getGameInstance();
            if (!ctx) return textureCache[rank];
            const bytes = b64bytes(data.b64);
            const arr = UE.NewArray(UE.BuiltinByte);
            for (let i = 0; i < bytes.length; i++) arr.Add(bytes[i]);
            const tex = UE.KismetRenderingLibrary.ImportBufferAsTexture2D(ctx, arr);
            textureCache[rank] = { tex: tex || null, w: data.w, h: data.h };
        } catch (e) {
            warn("texture " + rank + ": " + String(e));
        }
        return textureCache[rank];
    }

    function applyImage(rank) {
        const entry = getRankTexture(rank);
        if (!entry || !entry.tex || !widget) return;
        widget.SetBrushResourceObject(entry.tex);
        reslot(entry.w, entry.h);
    }

    function reslot(w, h) {
        if (!widget || !viewport || (w === slotW && h === slotH)) return;
        const off = new UE.Margin();
        off.Top = MARGIN;
        off.Left = viewportW - w - MARGIN;
        off.Right = MARGIN;                    // inset from right edge
        off.Bottom = viewportH - MARGIN - h;   // inset from bottom edge
        const slot = new UE.GameViewportWidgetSlot();
        slot.Offsets = off;
        slot.ZOrder = Z_ORDER;
        slot.bAutoRemoveOnWorldRemoved = false;
        viewport.RemoveWidget(widget);
        if (!viewport.AddWidget(widget, slot)) {
            warn("re-slot AddWidget failed");
        }
        slotW = w; slotH = h;
    }

    // Hand the badge widget's object name to the Lua mod (StylishAudio), which
    // animates it from the music beat. Re-written every time the widget is made.
    function publishWidgetName() {
        if (!widget) return;
        let nm = "";
        try { nm = String(widget.GetName()); } catch (e) { warn("widget name: " + String(e)); }
        if (!nm) { log("widget name unavailable"); return; }
        const path = audioFile("bgwidget.txt");
        if (!path) { log("widget name unavailable (no audio dir)"); return; }
        try {
            UE.EasyCsv.SaveStringToFileWithFullPath(nm, path);
            log("widget name -> " + nm);
        } catch (e) { warn("widget name write: " + String(e)); }
    }

    // ---- in-game volume popup -------------------------------------------------
    // StylishRank only CREATES the popup (PuerTS can draw but cannot read files).
    // The StylishAudio Lua mod reads volume.txt, finds these widgets by the
    // names published to volwidgets.txt, and shows/hides them plus lights the
    // 20 level blocks when the player presses [ or ].
    const VOL_PANEL_W = 480;
    const VOL_PANEL_H = 150;
    const VOL_BLOCKS = 20;             // 20 blocks = 5% per block
    const VOL_BLOCK_W = 18;
    const VOL_BLOCK_H = 16;
    const VOL_BLOCK_X0 = 31;           // inside the panel's meter track
    const VOL_BLOCK_Y0 = 96;
    const VOL_BLOCK_GAP = 3;
    const VOL_PANEL_B64 = "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";
    const VOL_BLOCK_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAADklEQVR42mP4DwUMMAYAj4IP8SHNGCcAAAAASUVORK5CYII=";

    let volTex = null;
    let volBlockTex = null;
    const volWidgets = [];             // [0] = panel, [1..] = level blocks

    function importPng(ctx, b64) {
        const bytes = b64bytes(b64);
        const arr = UE.NewArray(UE.BuiltinByte);
        for (let i = 0; i < bytes.length; i++) arr.Add(bytes[i]);
        return UE.KismetRenderingLibrary.ImportBufferAsTexture2D(ctx, arr);
    }

    function addViewportImage(gi, vp, tex, x, y, w, h, z, tint) {
        const img = UE.NewObject(UE.Image.StaticClass(), gi);
        img.SetVisibility(UE.ESlateVisibility.Collapsed);
        if (tex) img.SetBrushResourceObject(tex);
        if (tint) img.SetColorAndOpacity(tint);
        const off = new UE.Margin();
        off.Left = x;
        off.Top = y;
        off.Right = viewportW - x - w;
        off.Bottom = viewportH - y - h;
        const slot = new UE.GameViewportWidgetSlot();
        slot.Offsets = off;
        slot.ZOrder = z;
        slot.bAutoRemoveOnWorldRemoved = false;
        if (!vp.AddWidget(img, slot)) { warn("volume popup AddWidget failed"); return null; }
        volWidgets.push(img);
        return img;
    }

    function publishVolumeWidgetNames() {
        if (volWidgets.length < 2) return;
        const path = audioFile("volwidgets.txt");
        if (!path) return;
        const names = [];
        for (let i = 0; i < volWidgets.length; i++) {
            try {
                const n = String(volWidgets[i].GetName());
                if (n) names.push(n);
            } catch (e) {}
        }
        if (names.length < 2) { warn("volume popup: no widget names"); return; }
        try {
            UE.EasyCsv.SaveStringToFileWithFullPath(names.join(","), path);
            log("volume widgets -> " + names.length + " (" + names[0] + ")");
        } catch (e) { warn("volume widgets write: " + String(e)); }
    }

    // True while the panel + blocks still exist as UObjects. A level change or
    // world teardown can destroy them; the polling loop re-creates them then.
    function popupAlive() {
        if (!volWidgets.length) return false;
        try { return !!UE.KismetSystemLibrary.IsValid(volWidgets[0]); } catch (e) { return false; }
    }

    function createVolumePopup(gi, vp) {
        if (popupAlive()) return;
        if (volWidgets.length) {
            // Stale handles from a previous world: drop them and start over.
            for (let i = 0; i < volWidgets.length; i++) {
                try { if (vp) vp.RemoveWidget(volWidgets[i]); } catch (e) {}
            }
            volWidgets.length = 0;
            volTex = null; volBlockTex = null;
        }
        const ctx = getPawn() || gi;
        if (!ctx) { warn("volume popup: no context"); return; }
        try {
            volTex = importPng(ctx, VOL_PANEL_B64);
            volBlockTex = importPng(ctx, VOL_BLOCK_B64);
        } catch (e) { warn("volume popup texture: " + String(e)); }
        if (!volTex || !volBlockTex) { warn("volume popup: texture import failed"); return; }

        const px = Math.round((viewportW - VOL_PANEL_W) / 2);
        const py = Math.round((viewportH - VOL_PANEL_H) / 2);
        addViewportImage(gi, vp, volTex, px, py, VOL_PANEL_W, VOL_PANEL_H, Z_ORDER + 10, null);
        const tint = new UE.LinearColor(0.72, 0.90, 1.0, 1.0);
        for (let i = 0; i < VOL_BLOCKS; i++) {
            const bx = px + VOL_BLOCK_X0 + i * (VOL_BLOCK_W + VOL_BLOCK_GAP);
            addViewportImage(gi, vp, volBlockTex, bx, py + VOL_BLOCK_Y0, VOL_BLOCK_W, VOL_BLOCK_H, Z_ORDER + 11, tint);
        }
        publishVolumeWidgetNames();
    }

    function triggerRankSound(rank) {
        // Write a command for the persistent audio service (same trick as
        // PBZMapMarkers' debugFile: UE.EasyCsv.SaveStringToFileWithFullPath).
        try {
            const f = UE.EasyCsv && UE.EasyCsv.SaveStringToFileWithFullPath;
            if (!f) { warn("sound: EasyCsv unavailable"); return; }
            const path = audioFile("cmd.txt");
            if (!path) { warn("sound: no audio dir"); return; }
            f.call(UE.EasyCsv, "play " + rank, path);
        } catch (e) {
            warn("sound: " + String(e));
        }
    }

    function rankIndex(s) {
        let i = 0;
        for (let k = RANKS.length - 1; k >= 0; k--) {
            if (s >= RANK_MIN[k]) { i = k; break; }
        }
        return i;
    }
    function scoreToRank(s) {
        return RANKS[rankIndex(s)];
    }

    // ---- per-poll update ------------------------------------------------------
    let popupCheckAt = 0;
    let popupRecreates = 0;

    function updateRank() {
        // Self-heal: if the game destroyed the popup widgets (level load /
        // world change), create them again. Their names change, so the Lua mod
        // notices and rebinds. Capped to avoid churn if something else is wrong.
        const nowPop = Date.now();
        if (viewport && nowPop - popupCheckAt > 3000) {
            popupCheckAt = nowPop;
            if (!popupAlive() && popupRecreates < 8) {
                const gi2 = getGameInstance();
                if (gi2) {
                    popupRecreates++;
                    try { createVolumePopup(gi2, viewport); }
                    catch (e) { warn("volume popup recreate: " + String(e)); }
                }
            }
        }

        const pawn = getPawn();
        if (!pawn) { hideRank(); lastScoreTime = null; lastActionTime = null; return; }
        const anim = getAnim(pawn);
        if (!anim) { hideRank(); lastScoreTime = null; lastActionTime = null; return; }

        const inCombat = readFlag(anim, "GameplayTag_IsInCombat");
        const melee = readFlag(anim, "GameplayTag_IsMelee");
        const dash = readFlag(anim, "GameplayTag_IsDashing");
        const stance = readFlag(anim, "GameplayTag_IsStance");
        const montage = readFlag(anim, "CombatMontageActive");

        const health = readHealth(pawn);
        const deflect = readDeflect(pawn);
        let paused = false;
        try { paused = UE.GameplayStatics.IsGamePaused(pawn) === true; } catch (e) {}
        let anyPlaying = false;
        try { anyPlaying = anim.IsAnyMontagePlaying() === true; } catch (e) {}

        if (!readReported) {
            readReported = true;
            log("reads: health=" + (health === null ? "null" : health) +
                " deflect=" + (deflect === null ? "null" : JSON.stringify(deflect)));
        }

        const now = Date.now();
        if (!lastDebugLog || now - lastDebugLog >= 1000) {
            lastDebugLog = now;
            let mname = "none";
            try {
                const m = anim.GetCurrentActiveMontage();
                if (m && UE.KismetSystemLibrary.IsValid(m)) mname = String(m.GetName());
            } catch (e) {}
            const mExec = /(ExE|GEx|SEx)/i.test(mname) ? " exec=true" : "";
            log("DEBUG: inCombat=" + inCombat + " melee=" + melee + " dash=" + dash + " stance=" + stance +
                " montage=" + montage + " mname=" + mname + " paused=" + paused + mExec +
                " idleMs=" + (lastActionTime === null ? "-" : (now - lastActionTime)) +
                " score=" + score.toFixed(1) + " rank=" + currentRank);
        }

        if (paused) {
            // Map/menu open: hide the rank and freeze scoring (do not touch score).
            hideRank();
            lastScoreTime = null;
            lastActionTime = null;
            return;
        }

        if (inCombat !== true) {
            score = 0;
            prevHealth = health;
            prevDeflectTime = deflect ? deflect.hitGameTime : null;
            if (currentRank !== "D") { currentRank = "D"; }
            hideRank();
            lastScoreTime = null;
            lastActionTime = null;
            lastExecName = null;
            dSoundPlayed = false;
            return;
        }

        // The badge only appears once you have earned the lowest rank (D) --
        // entering combat and flailing at nothing keeps it hidden.
        if (score >= RANK_MIN[0]) {
            showRank();
            if (lastActionTime === null) lastActionTime = now;
        } else {
            hideRank();
        }

        // Real-time step for attack scoring (independent of timer drift).
        let dt = SCORE_WINDOW_MS / 1000;
        if (lastScoreTime !== null) {
            dt = (now - lastScoreTime) / 1000;
            if (!(dt >= 0) || dt > 0.5) dt = 0;
        }
        lastScoreTime = now;

        // Damage: health went down.
        if (health !== null && prevHealth !== null && health < prevHealth - 0.01) {
            score = Math.max(0, score - SCORE_DAMAGE);
            log("DAMAGED " + prevHealth.toFixed(1) + " -> " + health.toFixed(1) +
                " (score " + score + ")");
        }

        // Deflect event: a new deflect/dodge happened.
        let deflectHappened = false;
        if (deflect !== null && deflect.hitGameTime !== null &&
            prevDeflectTime !== null && deflect.hitGameTime > prevDeflectTime + 0.001) {
            deflectHappened = true;
            if (deflect.isHit === true) {
                score = Math.max(0, score - SCORE_DEFLECT_FAIL);
                log("DEFLECT FAIL (hit) (score " + score + ")");
            } else {
                score = Math.min(SCORE_MAX, score + SCORE_DEFLECT);
                log("DEFLECT SUCCESS (score " + score + ")");
            }
        }

        // "Attacking" is detected by the current montage name (GameplayTag_IsMelee
        // stays false even while attacking, so it is NOT usable). Blocking/dodging
        // are event-based (via the deflect system) and must NOT tick here.
        const mname = readMontageName(anim);
        const attacking = anyPlaying &&
            ((mname.indexOf("Attack") >= 0) || (mname.indexOf("Skill") >= 0));

        // Executions ("处决") leave the player invincible for several seconds and
        // are named ExE / GEx / SEx (e.g. Hun_BaiShanDual_ExE_F_01_Montage).
        // They are NOT "Attack"/"Skill", so without this they looked like idling.
        // Chain executions switch to another execution montage -> a new bonus.
        const executing = anyPlaying && /(ExE|GEx|SEx)/i.test(mname);

        if (attacking) {
            score = Math.min(SCORE_MAX, score + SCORE_MELEE * (dt / (SCORE_WINDOW_MS / 1000)));
        }

        if (executing) {
            if (lastExecName !== mname) {
                lastExecName = mname;
                score = Math.min(SCORE_MAX, score + SCORE_EXECUTION);
                log("EXECUTION " + mname + " (score " + score.toFixed(1) + ")");
            }
        } else {
            lastExecName = null;
        }

        // Passive play: standing in combat without attacking (or deflecting) for
        // longer than the grace period bleeds style, down to 0.
        // Any montage at all (execution, chain follow-up, block, dodge, hit
        // reaction) means the player is busy, so it must not drain.
        if (anyPlaying || deflectHappened) {
            lastActionTime = now;
        } else if (now - lastActionTime > IDLE_GRACE_MS && score > 0) {
            const before = score;
            score = Math.max(0, score - SCORE_IDLE_DRAIN * dt);
            if (before > 0 && score === 0) log("IDLE: score drained to 0");
        }

        prevHealth = health;
        prevDeflectTime = deflect ? deflect.hitGameTime : null;

        setRankIfChanged(scoreToRank(score));
    }

    function setRankIfChanged(rank) {
        if (rank !== currentRank) setRank(rank);
    }

    // ---- widget ---------------------------------------------------------------
    function setRank(rank) {
        if (RANKS.indexOf(rank) < 0) return false;
        const prevRank = currentRank;
        currentRank = rank;
        log("rank -> " + rank + " (score " + score.toFixed(1) + ")");
        // Play a sound only when climbing INTO a rank above D, at the exact moment
        // the icon changes (single source of truth, no drift).
        if (RANKS.indexOf(rank) > RANKS.indexOf(prevRank) && rank !== "D") {
            triggerRankSound(rank);
        }
        if (widget) { applyImage(rank); }
        return true;
    }
    function showRank() {
        if (!widget || shown) return;
        shown = true;
        log("SHOW rank");
        widget.SetVisibility(UE.ESlateVisibility.HitTestInvisible);
        applyImage(currentRank);
        // The badge first appears as rank D once you reach the D threshold.
        // Announce D once per fight (score can dip back under the gate and
        // re-show the badge; it must not replay the sound every time).
        if (currentRank === "D" && !dSoundPlayed) {
            dSoundPlayed = true;
            triggerRankSound("D");
        }
    }
    function hideRank() {
        if (!widget || !shown) return;
        shown = false;
        log("HIDE rank");
        widget.SetVisibility(UE.ESlateVisibility.Collapsed);
    }
    function startPoll() {
        if (pollTimer !== null) return;
        pollTimer = setInterval(function () {
            try { updateRank(); } catch (e) { warn("poll: " + String(e && e.stack || e)); }
        }, POLL_MS);
    }

    // ---- create widget --------------------------------------------------------
    function createWidget(gi, pc, vp) {
        if (created) return;
        const size = readViewportSize(pc);
        viewportW = size.w;
        viewportH = size.h;

        widget = UE.NewObject(UE.Image.StaticClass(), gi);
        widget.SetVisibility(UE.ESlateVisibility.HitTestInvisible);

        const entry = getRankTexture(INITIAL_RANK);
        if (entry && entry.tex) widget.SetBrushResourceObject(entry.tex);
        const w = (entry && entry.w) ? entry.w : SLOT_W;
        const h = (entry && entry.h) ? entry.h : SLOT_H;

        const off = new UE.Margin();
        off.Top = MARGIN;
        off.Left = viewportW - w - MARGIN;
        off.Right = MARGIN;                    // inset from right edge
        off.Bottom = viewportH - MARGIN - h;   // inset from bottom edge
        const slot = new UE.GameViewportWidgetSlot();
        slot.Offsets = off;
        slot.ZOrder = Z_ORDER;
        slot.bAutoRemoveOnWorldRemoved = false;
        log("viewport " + Math.round(viewportW) + "x" + Math.round(size.h) +
            " -> slot Left=" + Math.round(off.Left) + " size=" + w + "x" + h);
        if (!vp.AddWidget(widget, slot)) throw new Error("AddWidget returned false");

        viewport = vp;
        slotW = w; slotH = h;
        created = true;
        log("WIDGET DEBUG: vis=" + String(widget.GetVisibility()) +
            " opacity=" + String(widget.GetRenderOpacity()));

        publishWidgetName();
        createVolumePopup(gi, vp);
    }

    // ---- retry loop -----------------------------------------------------------
    function stopRetry() {
        if (retryTimer !== null) { clearInterval(retryTimer); retryTimer = null; }
    }
    function tick() {
        if (created) { stopRetry(); return; }
        retryCount++;
        const gi = getGameInstance();
        const pc = gi ? getPlayerController(gi) : null;
        const vp = getViewport();
        if (gi && !readyLog.gi) { log("GameInstance ready"); readyLog.gi = true; }
        if (pc && !readyLog.pc) { log("PlayerController ready"); readyLog.pc = true; }
        if (vp && !readyLog.viewport) { log("Viewport ready"); readyLog.viewport = true; }
        const missing = !gi ? "GameInstance" : !pc ? "PlayerController" : !vp ? "Viewport" : null;
        if (missing) {
            if (missing !== prevMissing) { log("Waiting for " + missing + "..."); prevMissing = missing; }
            else if (retryCount % 10 === 0) { log("Still waiting for " + missing + " (attempt " + retryCount + "/" + MAX_RETRIES + ")"); }
            if (retryCount >= MAX_RETRIES) { stopRetry(); warn("GAVE UP after " + retryCount + " attempts: " + missing + " never became ready"); }
            return;
        }
        prevMissing = null;
        try {
            createWidget(gi, pc, vp);
            stopRetry();
            log("Widget added (hidden until combat)");
            startPoll();
        } catch (e) {
            if (!created) { widget = null; }
            warn("create widget failed: " + String(e && e.stack || e));
            if (retryCount >= MAX_RETRIES) { stopRetry(); warn("GAVE UP after " + retryCount + " attempts: " + String(e && e.message || e)); }
        }
    }
    function startRetry() {
        if (retryTimer !== null) return;
        log("checking engine objects (every " + RETRY_MS + " ms, max " + MAX_RETRIES + " attempts)");
        retryCount = 0;
        prevMissing = undefined;
        retryTimer = setInterval(tick, RETRY_MS);
        tick();
    }

    function init() {
        log("init");
        startRetry();
    }

    globalThis.StylishRank = {
        setRank: setRank,
        getRank: function () { return currentRank; },
        getScore: function () { return score; },
        ranks: RANKS,
    };

    try { init(); } catch (e) { warn("init failed: " + String(e && e.stack || e)); }

    exports.stop = function () {
        log("stop");
        stopRetry();
        if (pollTimer !== null) { clearInterval(pollTimer); pollTimer = null; }
        if (animTimer !== null) { clearInterval(animTimer); animTimer = null; }
        if (widget && viewport) {
            try { viewport.RemoveWidget(widget); } catch (e) { warn("remove: " + String(e)); }
        }
        for (let i = 0; i < volWidgets.length; i++) {
            try { if (viewport) viewport.RemoveWidget(volWidgets[i]); } catch (e) {}
        }
        volWidgets.length = 0;
        volTex = null; volBlockTex = null;
        widget = null; viewport = null; created = false;
        if (globalThis.StylishRank) { delete globalThis.StylishRank; }
    };
})();
