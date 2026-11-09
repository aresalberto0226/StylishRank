# StylishRank — DMC5-style Style Rank for Phantom Blade Zero

Source code for the mod **StylishRank v1.0** published on Nexus Mods
(Phantom Blade Zero). This repository is provided so the distributed archive
can be reviewed and verified.

- Author: **AresAlberto** — aresalberto@gmail.com
- Game: Phantom Blade Zero (Steam, Unreal Engine 5.7)
- Requirements: [PBZModLoader](https://www.nexusmods.com/phantombladezero/mods/) and
  [UE4SS for Phantom Blade Zero](https://www.nexusmods.com/phantombladezero/mods/)
- Nothing here is obfuscated, packed, or encrypted. Every file below is the
  exact text that ships inside `StylishRank_v1.0.zip`.

---

## Two release archives

| Archive | Contents |
| --- | --- |
| `StylishRank_v1.0.zip` | mod files + one-click install/uninstall `.cmd` scripts |
| `StylishRank_v1.0_manual.zip` | identical mod files, **no `.cmd` scripts**; users copy the two folders in `payload/` by hand |

The manual edition exists because batch scripts are one of the file types that
automated scanners flag. Its manifest is in `RELEASE_CHECKSUMS_MANUAL.txt`, and
the manual instructions are `docs/安装说明_手动安装_CN.txt` and
`docs/Install_Guide_MANUAL_EN.txt`. Both archives contain the same `main.js`,
`main.lua`, `rank_service.ps1`, `.cs` sources and WAV audio.

---

## What the mod does

Adds a Devil May Cry 5 style battle rank badge (D → C → B → A → S → SS → SSS)
to the top-right corner of the screen. The rank rises with attacks, parries and
executions, drops when the player is hit or idles in combat, and resets when
combat ends. The badge pulses with the background music, a short sound effect
plays on each rank-up, and an in-game panel lets the player change the rank-up
volume with `[` / `]` (rebindable in `audio/keys.txt`).

Everything is client-side, single-player, and local. The mod makes no network
connections, does not modify `PBZ.exe` or any game asset, and does not touch
other mods.

---

## Repository layout → installed location

| Repository path | Installed path |
| --- | --- |
| `mod/StylishRank/main.js`, `rankImages.js` | `<Game>\ProjectPBZ\PBZModLoader\mods\StylishRank\` |
| `mod/StylishAudio/enabled.txt`, `Scripts/main.lua`, `audio/*` | `<Game>\platform\steam\ue4ss\Mods\StylishAudio\` |
| `installer/一键安装.cmd` (install) | run from the extracted archive root |
| `installer/一键卸载.cmd` (uninstall) | run from the extracted archive root |
| `docs/*` | user documentation (Chinese and English) |

The batch scripts are convenience wrappers only: they locate the Steam install
(via `HKCU\Software\Valve\Steam` `SteamPath` plus common fallback paths),
check that `platform\steam\PBZ.exe` exists, and copy the `mod/` tree with
`robocopy`. Users can install by hand by copying the two folders above
themselves; the scripts are not required at runtime.

---

## No build step — how each piece runs

There is **no compiled binary** in the release and there is nothing to build.

1. **`main.js` / `rankImages.js`** — JavaScript, executed at runtime by
   **PBZModLoader** (PuerTS / V8). `rankImages.js` stores the rank badge images
   as base64 strings embedded in the source. The JS side computes the score
   from montage/health/parry/pause state, creates the UMG widgets, and signals
   rank changes through small text files.
2. **`Scripts/main.lua`** — Lua, executed by **UE4SS**. It starts the audio
   helper, owns the volume value and key bindings, drives the badge's
   music-reactive scale/opacity, and manages the `[` `]` volume panel.
3. **`audio/rank_service.ps1`** — PowerShell, started once by the Lua file
   through `wscript.exe //B` (via a generated `.vbs` launcher) so it runs
   without a console window. It is a small local loop that:
   - reads `cmd.txt` for `play <rank>` commands written by the JS side,
   - plays the matching `*.WAV` with `System.Media.SoundPlayer`, and
   - samples the default audio output peak to write `levels.txt`.
4. **`audio/WavGain.cs`, `audio/PeakMeter.cs`** — C# **source**, compiled
   **in memory at runtime** by `rank_service.ps1` using PowerShell's
   `Add-Type`. Nothing is pre-compiled and no `.exe`/`.dll` is produced.
   - `WavGain.cs` normalizes a WAV's peak level and applies the user's volume,
     writing a temporary `_play_<rank>.wav`.
   - `PeakMeter.cs` uses the Windows Core Audio API
     (`IAudioMeterInformation`) to read the current output peak.
5. **`*.WAV`** — sound effects, included in the release archive (not in this
   repository, see *Third-party content* below).

**To reproduce the release archive:** copy `mod/StylishRank` and
`mod/StylishAudio` next to the two `.cmd` files and the `docs/` text files,
then zip the folder. No compiler is needed. (The WAV assets are shipped in the
Nexus upload.)

---

## Why automated scanners may flag the archive

This is expected for this kind of mod and is why the source is published here:

- `.cmd` / `.ps1` files are classified as "executables and similar file types".
- `rank_service.ps1` invokes `Add-Type`, i.e. it compiles the two `.cs` files
  at runtime. Some scanners label that as "compiled code" even though the
  source ships in plain text and no binary is distributed.
- The mod reads the audio output peak, which can resemble screen/audio capture
  behaviour to a heuristic engine.
- The whole thing is unsigned and newly published, which raises reputation
  scores.

There are no binaries, no packed/obfuscated payloads, no nested archives, no
auto-updaters, and no network code anywhere in this repository.

---

## Third-party content and credits

- Rank badge artwork: generated with AI, prompted by the author.
- Sound effects: recorded from **Devil May Cry 5**, © Capcom. Used for personal,
  non-commercial entertainment with no affiliation or endorsement implied.
- Mod code: written by the author with heavy AI assistance; the author does not
  program professionally.

## License

Free to download and use for personal, non-commercial purposes. No warranty of
any kind; use at your own risk. Please do not re-upload to other sites without
crediting the author.

## Contact

AresAlberto — aresalberto@gmail.com
