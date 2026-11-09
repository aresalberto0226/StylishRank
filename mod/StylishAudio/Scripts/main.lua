-- StylishAudio - rank-up sound service launcher.
--
-- The rank + scoring live in the StylishRank (PBZModLoader) mod, which is the
-- SINGLE source of truth. When its icon changes, it writes "play <rank>" to
-- audio\cmd.txt. This mod only launches one persistent PowerShell service that
-- polls that file and plays the matching WAV (WPF MediaPlayer, volume from
-- audio\volume.txt; SoundPlayer as fallback).
-- The in-game audio API is locked for mods, so audio is played out-of-process
-- (same technique as the PBZJelly mod).

local function Log(fmt, ...)
    print(string.format("[StylishAudio] " .. fmt .. "\n", ...))
end

local function IsValid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- ---- mod dir (reliable detection, like PBZJelly) --------------------------
local function norm_dir(p)
    if type(p) ~= 'string' then return nil end
    p = p:gsub('/', '\\'):gsub('\\+$', '')
    if p == '' then return nil end
    return p .. '\\'
end

-- ① 最可靠：UE4SS 引擎目录树（节点自带 __absolute_path）
local function dir_from_tree()
    if type(IterateGameDirectories) ~= 'function' then return nil end
    local ok, root = pcall(IterateGameDirectories)
    if not ok or type(root) ~= 'table' then return nil end
    local found, visits = nil, 0
    local seen = {}
    local function walk(node, depth)
        if found ~= nil or type(node) ~= 'table' or depth > 8 or seen[node] then return end
        seen[node] = true
        visits = visits + 1
        if visits > 20000 then return end
        if node.__name == 'StylishAudio' and type(node.__absolute_path) == 'string' then
            local cand = norm_dir(node.__absolute_path)
            -- Only accept the installed copy inside the UE4SS mods folder.
            -- The mod package itself contains payload/StylishAudio; if the
            -- archive was extracted anywhere under the game directory, this
            -- walk would otherwise pick the payload copy and every file Lua
            -- reads or writes (keys/volume/cmd/bgwidget/levels) would land in
            -- the wrong folder: no sounds, no volume panel, no music pulse.
            if cand and cand:lower():find('\\ue4ss\\mods\\', 1, true) then
                found = cand
                return
            end
        end
        for k, v in pairs(node) do
            if type(v) == 'table' then
                walk(v, depth + 1)
                if found ~= nil then return end
            end
        end
    end
    walk(root, 1)
    return found
end

-- ② 兜底：脚本自身位置
local function dir_from_script()
    local ok, info = pcall(debug.getinfo, 1, 'S')
    if not ok or type(info) ~= 'table' then return nil end
    local raw = info.source
    if type(raw) == 'string' and raw ~= '' then
        local p = raw:gsub('^@', '')
        local d = p:match('^(.*)[/\\]Scripts[/\\][^/\\]+$')
        if type(d) == 'string' and d ~= '' then return norm_dir(d) end
    end
    return nil
end

-- Pick the first candidate that actually contains our service script.
-- dir_from_script() is exact (the folder UE4SS loaded this file from), so it
-- is tried first; dir_from_tree() is the fallback.
local function dir_has_service(d)
    if type(d) ~= 'string' or d == '' then return false end
    local f = io.open(d .. 'audio\\rank_service.ps1', 'r')
    if f then f:close(); return true end
    return false
end

local MOD_DIR = nil
for _, d in ipairs({ dir_from_script() or '', dir_from_tree() or '' }) do
    if dir_has_service(d) then
        MOD_DIR = d
        break
    end
end
if not MOD_DIR then MOD_DIR = dir_from_tree() or dir_from_script() or '' end
local AUDIO_DIR = MOD_DIR .. 'audio\\'

-- ---- audio service (persistent PowerShell, commanded via file) ------------
local SERVICE = AUDIO_DIR .. "rank_service.ps1"
local F_CMD = AUDIO_DIR .. "cmd.txt"
local F_ALIVE = AUDIO_DIR .. "alive.txt"
local VBS = AUDIO_DIR .. "launch_service.vbs"

-- The service rewrites alive.txt every second while it runs.
local function ServiceAlive()
    local f = io.open(F_ALIVE, 'r')
    if not f then return false end
    local s = f:read('*a') or ''
    f:close()
    local t = tonumber(s:match('(%d+)') or '')
    return t ~= nil and (os.time() - t) <= 10
end

-- Write a tiny VBS launcher: wscript starts PowerShell fully detached (its own
-- process, no console inheritance) and returns immediately. Running the script
-- through `start /b` from the game's console could fail with 0x800700e8
-- ("pipe being closed") and block the caller on an error dialog.
local function WriteLauncher()
    local f = io.open(VBS, 'w')
    if not f then return false end
    local ps = 'powershell -NoProfile -WindowStyle Hidden -File "' .. SERVICE ..
               '" -CmdPath "' .. F_CMD .. '"'
    f:write('Set sh = CreateObject("WScript.Shell")\r\n')
    f:write('sh.Run "' .. ps:gsub('"', '""') .. '", 0, False\r\n')
    f:close()
    return true
end

local function LaunchService()
    if WriteLauncher() then
        local ok, err = pcall(os.execute, 'wscript.exe //B //Nologo "' .. VBS .. '" >nul 2>&1 <nul')
        Log("launch (wscript) ok=" .. tostring(ok) .. " " .. tostring(err))
        return ok
    end
    local cmd = 'start "" /b powershell -NoProfile -WindowStyle Hidden -File "' ..
                SERVICE .. '" -CmdPath "' .. F_CMD .. '" >nul 2>&1 <nul'
    local ok, err = pcall(os.execute, cmd)
    Log("launch (start) ok=" .. tostring(ok) .. " " .. tostring(err))
    return ok
end

local attempts = 0
local MAX_ATTEMPTS = 3

local function EnsureService()
    attempts = attempts + 1
    if ServiceAlive() then
        Log("service alive (attempt " .. attempts .. ")")
        return
    end
    if attempts > MAX_ATTEMPTS then
        Log("service NOT running after " .. MAX_ATTEMPTS .. " attempts - rank sounds are off")
        return
    end
    LaunchService()
    ExecuteInGameThreadWithDelay(12000, function()
        if ServiceAlive() then
            Log("service alive after attempt " .. attempts)
        else
            Log("service not alive after attempt " .. attempts .. ", retrying")
            EnsureService()
        end
    end)
end

-- ---- music-reactive rank badge --------------------------------------------
-- StylishRank (JS) draws the rank badge and writes that UImage's object name
-- to bgwidget.txt (PuerTS can only write files, never read them).
-- rank_service.ps1 samples the system audio ~30x/s and writes "<beat> <peak>"
-- to levels.txt. Here we find the badge by name and drive its scale/opacity
-- so it pumps with the music.
local F_RING   = AUDIO_DIR .. 'bgwidget.txt'
local F_LEVELS = AUDIO_DIR .. 'levels.txt'

local ring      = nil
local ringName  = nil
local ringTick  = 0
local beat      = 0.0
local peak      = 0.0
local animFail  = false

local function ReadAll(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function Trim(s)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('^\239\187\191', '')          -- UTF-8 BOM, if EasyCsv wrote one
    s = s:gsub('%s', '')                     -- names contain no spaces
    if s == '' then return nil end
    return s
end

local function FindImageByName(name)
    local classes = { 'Image', '/Script/UMG.Image' }
    for _, cls in ipairs(classes) do
        local ok, objs = pcall(FindAllOf, cls)
        if ok and type(objs) == 'table' then
            for _, o in ipairs(objs) do
                if IsValid(o) then
                    local okn, n = pcall(function() return o:GetName() end)
                    if okn and n == name then return o end
                    local okf, full = pcall(function() return o:GetFullName() end)
                    if okf and type(full) == 'string' and full:find(name, 1, true) then return o end
                end
            end
        end
    end
    return nil
end

-- ---- in-game volume popup ---------------------------------------------------
-- StylishRank (JS) creates the panel + 20 level blocks and publishes their
-- object names to volwidgets.txt. Lua owns the value here: the down/up keys
-- change the rank-up volume and pop the panel up for a few seconds, and the
-- value is written to volume.txt (read by rank_service.ps1 before every
-- sound), so it persists across game launches. The keys are configurable in
-- audio\keys.txt (defaults: [ and ]); see the rebindable-keys section below.
local F_VOLWID  = AUDIO_DIR .. 'volwidgets.txt'
local VOL_PATH  = AUDIO_DIR .. 'volume.txt'
local VOL_BLOCKS = 20
local VOL_STEP   = 5
local VOL_MAX    = 200          -- 0..200 %; 100 = normalised standard loudness
local VOL_HIDE_TICKS = 150      -- auto-close after ~5 s (33 ms per tick)
local VOL_PLAY_TICKS = 15       -- preview sound ~0.5 s after the last change

local volKey     = ''           -- published names, to detect a widget rebuild
local volBound   = false
local volLastGot = -1
local volPanel   = nil
local volBlocks  = {}
local volOpen    = false
local volValue   = 100
local volHideAt  = 0
local volPlayAt  = 0
local volDirty   = true

local function ReadVolume()
    local s = ReadAll(VOL_PATH)
    local n = nil
    if s then n = tonumber(s:match('%-?%d+%.?%d*')) end
    if not n then return 100 end
    if n > 0 and n < 1 then n = n * 100 end       -- also accept 0..1 fractions
    if n < 0 then n = 0 elseif n > VOL_MAX then n = VOL_MAX end
    return n
end

local function WriteVolume(v)
    local f = io.open(VOL_PATH, 'w')
    if not f then return false end
    f:write(string.format('%.0f', v))
    f:close()
    return true
end

local function BindVolWidgets()
    -- Widgets can vanish on a level change / JS hot reload: drop them and
    -- rebind from scratch. Also retries until every published name resolves,
    -- which matters right after a game start (volwidgets.txt may still hold
    -- the previous session's names for a moment).
    if volPanel ~= nil and not IsValid(volPanel) then
        volPanel, volBlocks, volBound = nil, {}, false
    end
    if volBound and volPanel ~= nil then return end

    local s = ReadAll(F_VOLWID)
    if not s then return end
    local names = {}
    for name in s:gmatch('[^,%s]+') do names[#names + 1] = name end
    if #names < 2 then return end
    local key = table.concat(names, ',')

    -- Collect every UImage once; exact name first, full-name substring as a
    -- fallback (the same trick FindImageByName uses for the badge).
    local byName, objects = {}, {}
    local classes = { 'Image', '/Script/UMG.Image' }
    for _, cls in ipairs(classes) do
        local ok, objs = pcall(FindAllOf, cls)
        if ok and type(objs) == 'table' then
            for _, o in ipairs(objs) do
                if IsValid(o) then
                    objects[#objects + 1] = o
                    local okn, n = pcall(function() return o:GetName() end)
                    if okn and type(n) == 'string' and not byName[n] then byName[n] = o end
                end
            end
        end
    end

    local function wordChar(c)
        return c ~= '' and c:match('[%w_]') ~= nil
    end

    local function lookup(name)
        if byName[name] then return byName[name] end
        -- Fallback: UE4SS's Lua GetName() does not always return the same text
        -- PuerTS wrote, but GetFullName() contains it. Require word boundaries
        -- so Image_...411 does not match Image_...4115.
        for _, o in ipairs(objects) do
            local okf, full = pcall(function() return o:GetFullName() end)
            if okf and type(full) == 'string' then
                if full == name then return o end
                local s, e = full:find(name, 1, true)
                if s then
                    local before = s > 1 and full:sub(s - 1, s - 1) or ''
                    local after = e < #full and full:sub(e + 1, e + 1) or ''
                    if not wordChar(before) and not wordChar(after) then return o end
                end
            end
        end
        return nil
    end

    local panel = lookup(names[1])
    if panel == nil then
        if key ~= volKey then
            volKey = key
            local sample = {}
            for i = 1, math.min(5, #objects) do
                local okn, n = pcall(function() return objects[i]:GetName() end)
                if okn and type(n) == 'string' then sample[#sample + 1] = n end
            end
            Log('volume popup: ' .. #objects .. ' images in memory, panel not found: ' ..
                names[1] .. ' (sample: ' .. table.concat(sample, ', ') .. ')')
        end
        return
    end

    volPanel = panel
    volBlocks = {}
    local got = 0
    for i = 2, #names do
        volBlocks[i - 1] = lookup(names[i])
        if volBlocks[i - 1] ~= nil then got = got + 1 end
    end
    volKey = key
    volDirty = true
    volBound = (got == VOL_BLOCKS and #names == VOL_BLOCKS + 1)
    if (got + 1) ~= volLastGot then
        volLastGot = got + 1
        Log('volume popup bound: ' .. (got + 1) .. ' widgets')
    end
end

local function ApplyVolumePopup()
    if volPanel == nil then return end
    local lit = math.floor(volValue * VOL_BLOCKS / VOL_MAX + 0.5)   -- 20 blocks of 10%
    if lit < 0 then lit = 0 elseif lit > VOL_BLOCKS then lit = VOL_BLOCKS end
    local vis = volOpen and 3 or 1                  -- HitTestInvisible / Collapsed
    pcall(function() volPanel:SetVisibility(vis) end)
    for i = 1, VOL_BLOCKS do
        local blk = volBlocks[i]
        if blk ~= nil then
            local v = 1
            if volOpen and i <= lit then v = 3 end
            pcall(function() blk:SetVisibility(v) end)
        end
    end
end

local function ChangeVolume(delta)
    volValue = ReadVolume() + delta
    if volValue < 0 then volValue = 0 elseif volValue > VOL_MAX then volValue = VOL_MAX end
    WriteVolume(volValue)
    volOpen = true
    volHideAt = ringTick + VOL_HIDE_TICKS
    volPlayAt = ringTick + VOL_PLAY_TICKS
    volDirty = true
    Log('volume -> ' .. string.format('%.0f', volValue))
end

-- ---- rebindable keys (audio\keys.txt) --------------------------------------
-- UE4SS has no "unregister key" call, so we register EVERY key once and decide
-- at press time whether it is one of our two actions. That lets keys.txt be
-- edited while the game is running: the change applies within ~2 s.
local F_KEYS = AUDIO_DIR .. 'keys.txt'
local keysRaw = nil

local KEY_DEFAULTS = { down = 'OEM_FOUR', up = 'OEM_SIX' }
local KEY_FALLBACK = { down = 'F7', up = 'F8' }
local bindings     = {}         -- action -> key code
local bindingLabel = {}         -- action -> key name, for the log

-- UE4SS exposes Windows virtual-key names: '[' is OEM_FOUR, ']' OEM_SIX,
-- '/' OEM_TWO, '\' OEM_FIVE, ';' OEM_ONE, ''' OEM_SEVEN, ',' OEM_COMMA,
-- '.' OEM_PERIOD, '-' OEM_MINUS, '=' OEM_PLUS, '`' OEM_THREE.
local KEY_ALIASES = {
    ['[']  = 'OEM_FOUR',  [']']  = 'OEM_SIX',    ['/']  = 'OEM_TWO',
    ['\\'] = 'OEM_FIVE',  [';']  = 'OEM_ONE',    ["'"] = 'OEM_SEVEN',
    [',']  = 'OEM_COMMA', ['.']  = 'OEM_PERIOD', ['-'] = 'OEM_MINUS',
    ['`']  = 'OEM_THREE',
}
local KEY_WORD_ALIASES = {
    ENTER = 'RETURN', ESC = 'ESCAPE', INSERT = 'INS', DELETE = 'DEL',
    UP = 'UP_ARROW', DOWN = 'DOWN_ARROW', LEFT = 'LEFT_ARROW', RIGHT = 'RIGHT_ARROW',
    PGUP = 'PAGE_UP', PGDN = 'PAGE_DOWN', SPACEBAR = 'SPACE',
}
local KEY_CANDIDATES = {
    OEM_FOUR   = { 'OEM_FOUR', 'OEM_4', 'LEFT_BRACKET', 'LBRACKET' },
    OEM_SIX    = { 'OEM_SIX', 'OEM_6', 'RIGHT_BRACKET', 'RBRACKET' },
    OEM_TWO    = { 'OEM_TWO', 'OEM_2', 'SLASH' },
    OEM_ONE    = { 'OEM_ONE', 'OEM_1', 'SEMICOLON' },
    OEM_THREE  = { 'OEM_THREE', 'OEM_3', 'TILDE' },
    OEM_FIVE   = { 'OEM_FIVE', 'OEM_5', 'BACKSLASH' },
    OEM_SEVEN  = { 'OEM_SEVEN', 'OEM_7', 'QUOTE' },
    OEM_COMMA  = { 'OEM_COMMA', 'COMMA' },
    OEM_PERIOD = { 'OEM_PERIOD', 'PERIOD' },
    OEM_MINUS  = { 'OEM_MINUS', 'HYPHEN' },
    OEM_PLUS   = { 'OEM_PLUS', 'EQUAL' },
}
local DIGIT_NAMES = { 'ZERO', 'ONE', 'TWO', 'THREE', 'FOUR',
                      'FIVE', 'SIX', 'SEVEN', 'EIGHT', 'NINE' }

local KEYS_TEMPLATE = [[
# StylishAudio 升阶音量按键设置
# 保存后约 2 秒内自动生效，不用重启游戏。
# 等号右边填按键名：
#   A-Z、0-9、F1-F12
#   符号： [ ] / \ ; ' , . - = `
#   特殊： SPACE TAB ENTER ESC HOME END INS DEL UP_ARROW DOWN_ARROW 等
# 和游戏或其他 mod 冲突时，把对应那行换成别的键即可。
down = [
up = ]
]]

local function ResolveKeyName(raw)
    if type(Key) ~= 'table' then return nil end
    local s = tostring(raw or '')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    s = s:gsub('^[Kk][Ee][Yy]%s*[%.:]%s*', '')      -- accept "Key.F7"
    if s == '=' then s = 'OEM_PLUS' end
    local up = s:upper():gsub('%s+', '_')          -- "page up" -> PAGE_UP
    if #up == 1 and up:match('^[A-Z0-9]$') then
        if up:match('%d') then up = DIGIT_NAMES[tonumber(up) + 1] end
        local code = Key[up]
        if type(code) == 'number' then return code, up end
        return nil
    end
    local mapped = KEY_ALIASES[s] or KEY_ALIASES[up] or KEY_WORD_ALIASES[up] or up
    local candidates = KEY_CANDIDATES[mapped] or { mapped }
    for _, candidate in ipairs(candidates) do
        local code = Key[candidate]
        if type(code) == 'number' then return code, candidate end
    end
    return nil
end

local function ParseKeysConfig(text)
    local values = {}
    if type(text) ~= 'string' then return values end
    text = text:gsub('\r', ''):gsub('\239\187\191', ''):gsub('＝', '=')
    for line in text:gmatch('[^\n]+') do
        line = line:gsub('^%s+', '')
        if line ~= '' and line:sub(1, 1) ~= '#' then
            local name, value = line:match('^([^=]+)=(.*)$')
            if name then
                name = name:gsub('%s+$', ''):lower()
                values[name] = value
            end
        end
    end
    return values
end

local function ApplyBindings(values, announce)
    local function pick(action)
        local raw = values[action]
        local code, label = ResolveKeyName(raw)
        if code then return code, label end
        if raw ~= nil then
            Log('keys: invalid ' .. action .. ' = "' .. tostring(raw) .. '", using default')
        end
        code, label = ResolveKeyName(KEY_DEFAULTS[action])
        if code then return code, label end
        code, label = ResolveKeyName(KEY_FALLBACK[action])
        if code then
            Log('keys: default key for ' .. action .. ' missing, using ' .. label)
            return code, label
        end
        return nil, '?'
    end

    local newBind, newLabel = {}, {}
    newBind.down, newLabel.down = pick('down')
    newBind.up,   newLabel.up   = pick('up')

    if newBind.down ~= nil and newBind.down == newBind.up then
        Log('keys: WARNING - both actions share the same key')
    end

    local changed = false
    for _, action in ipairs({ 'down', 'up' }) do
        if bindings[action] ~= newBind[action] then changed = true end
    end
    bindings, bindingLabel = newBind, newLabel
    if announce or changed then
        Log('keys: [' .. tostring(newLabel.down) .. '] -   [' .. tostring(newLabel.up) .. '] +')
    end
end

local function LoadBindings(announce)
    local text = ReadAll(F_KEYS)
    if text == nil then
        local f = io.open(F_KEYS, 'w')
        if f then f:write(KEYS_TEMPLATE); f:close() end
        text = ReadAll(F_KEYS)
        if announce then Log('keys: created ' .. F_KEYS) end
    end
    keysRaw = text
    ApplyBindings(ParseKeysConfig(text), announce)
end

local function DispatchKey(code)
    if code == bindings.down then
        pcall(ChangeVolume, -VOL_STEP)
    elseif code == bindings.up then
        pcall(ChangeVolume, VOL_STEP)
    end
end

if type(RegisterKeyBind) == 'function' and type(Key) == 'table' then
    local seen, count = {}, 0
    for name, code in pairs(Key) do
        if type(name) == 'string' and type(code) == 'number' and not seen[code] then
            seen[code] = true
            local c = code
            if pcall(RegisterKeyBind, c, function() DispatchKey(c) end) then
                count = count + 1
            end
        end
    end
    Log('keys: listening on ' .. count .. ' keys')
else
    Log('keys: RegisterKeyBind/Key missing - volume hotkeys disabled')
end

LoadBindings(true)

local function RingTick()
    ringTick = ringTick + 1

    -- 1) music level: "<beat> <peak>". Reading a file from the game thread is
    -- not free, so poll it 10 times/s and keep animating from the cached value
    -- in between (the badge is still scaled/tinted every 33 ms).
    if (ringTick % 3) == 1 then
        local lv = ReadAll(F_LEVELS)
        local b, p = nil, nil
        if lv then b, p = lv:match('^%s*(%d+%.?%d*)%s+(%d+%.?%d*)') end
        if b and p then
            beat, peak = tonumber(b), tonumber(p)
        else
            beat = beat * 0.85      -- service gone: fall back to plain breathing
            peak = peak * 0.85
        end
    end

    -- 2) (re)find the badge: every ~2 s, or at once when its name changes
    -- (StylishRank rewrites bgwidget.txt after a hot reload).
    if ring ~= nil and not IsValid(ring) then ring, ringName = nil, nil end

    if (ringTick % 60) == 1 then
        local nm = Trim(ReadAll(F_RING))
        if nm and nm ~= ringName then
            ringName = nm
            ring = FindImageByName(nm)
            if ring then Log('ring bound: ' .. nm)
            else Log('ring not found yet: ' .. nm) end
        elseif nm and ring == nil then
            ring = FindImageByName(nm)
            if ring then Log('ring re-bound: ' .. nm) end
        end
    end

    -- 2b) volume popup: rebind when JS publishes new widget names, apply
    -- changes, auto-close after a few seconds, preview the new volume.
    if (ringTick % 60) == 1 then
        BindVolWidgets()
        -- pick up edits to keys.txt without a restart (~2 s)
        local ks = ReadAll(F_KEYS)
        if ks ~= nil and ks ~= keysRaw then
            keysRaw = ks
            ApplyBindings(ParseKeysConfig(ks), true)
        end
    end
    if volOpen and ringTick > volHideAt then
        volOpen = false
        volDirty = true
    end
    if volDirty then
        volDirty = false
        ApplyVolumePopup()
    end
    if volPlayAt > 0 and ringTick >= volPlayAt then
        volPlayAt = 0
        local f = io.open(AUDIO_DIR .. 'cmd.txt', 'w')
        if f then f:write('play D'); f:close() end
    end

    if ring == nil then return end

    -- 3) animate (skip while the mod has the badge hidden)
    local vis = nil
    pcall(function() vis = ring:GetVisibility() end)
    if type(vis) == 'number' and vis <= 2 then return end

    -- 4) badge: breathe + punch on the beat
    -- Bigger, punchier motion: the badge is 300x300 with a larger margin,
    -- so it can swell up to ~1.28x on a hard hit without clipping the edge.
    local breath = 0.5 + 0.5 * math.sin(ringTick * 0.055)
    local amp = beat
    if amp > 2.2 then amp = 2.2 end
    local scale = 1.0 + 0.03 * breath + 0.13 * amp

    -- White flash on the beat: tint brightness above 1.0 (HDR) makes the
    -- badge "glow" on every hit and settle back to its own colour.
    local glow = 1.0 + 0.28 * amp
    if glow > 1.6 then glow = 1.6 end

    -- Only scale + tint are written here. Opacity is left untouched so the
    -- badge stays fully opaque; visibility is controlled by StylishRank (JS).
    local ok, err = pcall(function()
        ring:SetRenderScale({ X = scale, Y = scale })
        ring:SetColorAndOpacity({ R = glow, G = glow, B = glow, A = 1.0 })
    end)
    if not ok and not animFail then
        animFail = true
        Log('ring anim error: ' .. tostring(err))
    end
end

if type(LoopInGameThreadWithDelay) == 'function' then
    LoopInGameThreadWithDelay(33, function() pcall(RingTick) end)
    Log('ring bridge loop started')
else
    Log('ring bridge: LoopInGameThreadWithDelay missing, ring stays static')
end

Log("loaded - audio dir: " .. AUDIO_DIR)
ExecuteInGameThreadWithDelay(5000, EnsureService)
