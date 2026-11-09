param([string]$CmdPath, [string]$GameProcessName = 'PBZ')
# StylishAudio service (persistent, launched once per game start).
#  * Polls cmd.txt (~every 165ms); "play <rank>" plays the matching WAV.
#    Volume comes from volume.txt (0-200, editable while the game runs).
#  * Samples the default output device's peak level ~30x/s (PeakMeter.cs),
#    runs a tiny onset/beat detector, and writes "beat peak" to levels.txt.
#    The StylishAudio Lua mod reads that file and animates the StylishRank
#    badge (scale/glow).
#  * Rewrites alive.txt every second so the Lua mod can verify it started.
#  * Exits when the game process is gone. A named mutex prevents duplicates.
$ErrorActionPreference = 'Continue'
$AlivePath = Join-Path $PSScriptRoot 'alive.txt'
$LevelPath = Join-Path $PSScriptRoot 'levels.txt'
$MeterErr  = Join-Path $PSScriptRoot 'meter_error.txt'
$VolPath   = Join-Path $PSScriptRoot 'volume.txt'

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\StylishAudioService')
    if (-not $mutex.WaitOne(0)) { exit }
} catch { }

# Drop files left over from a previous session (avoid a stale sound / level).
Remove-Item -LiteralPath $CmdPath   -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LevelPath -Force -ErrorAction SilentlyContinue

# ---- system audio peak meter (non-fatal: sounds still work without it) ----
$meterOk = $false
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'PeakMeter.cs') -ErrorAction Stop
    $meterOk = [PeakMeter]::Init()
    if (-not $meterOk) {
        try { [System.IO.File]::WriteAllText($MeterErr, [string][PeakMeter]::LastError) } catch { }
    }
} catch {
    try { [System.IO.File]::WriteAllText($MeterErr, [string]$_.Exception.Message) } catch { }
}

$inv      = [Globalization.CultureInfo]::InvariantCulture

# ---- rank-up volume (0-200 in volume.txt; editable while the game runs) ----
# Accepts 0-200 (percent) or 0-1 (fraction). Re-read for every sound, so the
# user can change it mid-session without restarting anything.
# 100 = standard loudness (files normalised); above 100 amplifies and may clip.
if (-not (Test-Path -LiteralPath $VolPath)) {
    try { [System.IO.File]::WriteAllText($VolPath, '100') } catch { }
}
function GetVolume {
    $v = 1.0
    try {
        $s = Get-Content -LiteralPath $VolPath -Raw -ErrorAction Stop
        if ($s) {
            $n = 0.0
            $ok = [double]::TryParse($s.Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$n)
            if ($ok) {
                if ($n -gt 0 -and $n -lt 1) { $n = $n * 100.0 }
                if ($n -lt 0) { $n = 0.0 } elseif ($n -gt 200.0) { $n = 200.0 }
                $v = $n / 100.0
            }
        }
    } catch { }
    return $v
}

# SoundPlayer has no volume control, so every sound is rendered into a temp WAV
# through WavGain.cs: it first normalises the file to a common peak (D/C/B are
# mixed much quieter than S/SS/SSS) and then applies the user volume (0-200%).
$gainOk = $false
try { Add-Type -Path (Join-Path $PSScriptRoot 'WavGain.cs') -ErrorAction Stop; $gainOk = $true } catch { }
Get-ChildItem -LiteralPath $PSScriptRoot -Filter '_play_*.wav' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$avg      = 0.01     # slow baseline of the music level (EMA)
$beat     = 0.0      # decaying pulse driven by onsets, 0..1.6
$tick     = 0
$lastAlive = -1
$players  = @()      # keep player refs alive while playing async

while ($true) {
    $tick++

    # Process check ~once a second.
    if (($tick % 30) -eq 0) {
        try { if (-not (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue)) { exit } } catch { }
    }

    # Heartbeat for the Lua mod.
    $nowSec = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($nowSec -ne $lastAlive) {
        $lastAlive = $nowSec
        try { [System.IO.File]::WriteAllText($AlivePath, [string]$nowSec) } catch { }
    }

    # ---- audio analysis ----
    $peak = -1.0
    if ($meterOk) {
        try { $peak = [PeakMeter]::Peak() } catch { $peak = -1.0 }
        if ($peak -ge 0) {
            # Faster baseline so it hugs the music and catches every kick.
            $avg = $avg * 0.90 + $peak * 0.10
            if ($avg -lt 0.004) { $avg = 0.004 }

            # Onset: peak jumps well above the running average. Lower threshold
            # and higher gain make the low-end "动次打次" hit harder.
            if ($peak -gt 0.015 -and $peak -gt ($avg * 1.12)) {
                $s = 0.5 + (($peak / $avg) - 1.12) * 1.5
                if ($s -gt 2.2) { $s = 2.2 }
                if ($s -gt $beat) { $beat = $s }
            }
            $beat = $beat * 0.92          # slower decay -> the pulse lingers
            if ($beat -lt 0.002) { $beat = 0.0 }
        }
    }

    # levels.txt: "<beat> <peak>"
    $pk = 0.0
    if ($peak -ge 0) { $pk = [math]::Min(1.0, $peak) }
    $line = [string]::Format($inv, '{0:F3} {1:F3}', $beat, $pk)
    try { [System.IO.File]::WriteAllText($LevelPath, $line) } catch { }

    # ---- rank sound command ----
    if (($tick % 5) -eq 0) {
        try {
            if (Test-Path -LiteralPath $CmdPath) {
                $cmd = (Get-Content -LiteralPath $CmdPath -Raw).Trim()
                # Delete the command BEFORE playing, so a new command written
                # during playback is picked up next loop instead of being lost.
                Remove-Item -LiteralPath $CmdPath -Force -ErrorAction SilentlyContinue
                if ($cmd -match '^play\s+(\S+)$') {
                    $rank = $Matches[1]
                    $wav = Join-Path $PSScriptRoot ($rank + '.WAV')
                    if (Test-Path -LiteralPath $wav) {
                        # Scale the samples when the volume is below 100% (the
                        # SoundPlayer API itself has no volume). Load() reads the
                        # whole file into memory, so the temp file can be
                        # overwritten by the next sound safely.
                        $src = $wav
                        $vol = GetVolume
                        if ($gainOk) {
                            $tmp = Join-Path $PSScriptRoot ('_play_' + $rank + '.wav')
                            try { if ([WavGain]::Convert($wav, $tmp, $vol)) { $src = $tmp } } catch { }
                        }
                        # Play asynchronously so audio sampling never stalls.
                        $p = New-Object System.Media.SoundPlayer $src
                        $p.Load()
                        $p.Play()
                        $players += $p
                        while ($players.Count -gt 4) {
                            try { $players[0].Dispose() } catch { }
                            $players = @($players[1..($players.Count - 1)])
                        }
                    }
                }
            }
        } catch { }
    }

    Start-Sleep -Milliseconds 33
}
