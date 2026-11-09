@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 936 >nul
title StylishRank 一键安装
set "PKG=%~dp0"
cd /d "!PKG!"

set "GAME="
set "SKIPRUN="
:parseargs
if "%~1"=="" goto argsdone
if /i "%~1"=="--allow-running" (
    set "SKIPRUN=1"
    shift
    goto parseargs
)
set "GAME=%~1"
shift
goto parseargs
:argsdone

echo.
echo   StylishRank - Phantom Blade Zero combat rank mod
echo   -----------------------------------------------
echo   影之刃零 DMC5 风格评级 + 升阶音效  一键安装
echo.

if not exist "!PKG!payload\StylishRank\main.js" goto nopayload

rem ---------- 定位游戏目录 ----------
if defined GAME if not exist "!GAME!\platform\steam\PBZ.exe" set "GAME="

if not defined GAME (
    set "STEAM="
    for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| findstr /i "SteamPath"') do set "STEAM=%%B"
    if defined STEAM set "STEAM=!STEAM:/=\!"
    if defined STEAM if exist "!STEAM!\steamapps\common\PBZ\platform\steam\PBZ.exe" set "GAME=!STEAM!\steamapps\common\PBZ"
)

if not defined GAME (
    for %%D in ("%ProgramFiles(x86)%" "%ProgramFiles%") do (
        if exist "%%~D\Steam\steamapps\common\PBZ\platform\steam\PBZ.exe" set "GAME=%%~D\Steam\steamapps\common\PBZ"
    )
)

if not defined GAME (
    for %%R in (C D E F G H) do (
        if not defined GAME if exist "%%R:\SteamLibrary\steamapps\common\PBZ\platform\steam\PBZ.exe" set "GAME=%%R:\SteamLibrary\steamapps\common\PBZ"
        if not defined GAME if exist "%%R:\Steam\steamapps\common\PBZ\platform\steam\PBZ.exe" set "GAME=%%R:\Steam\steamapps\common\PBZ"
        if not defined GAME if exist "%%R:\Games\SteamLibrary\steamapps\common\PBZ\platform\steam\PBZ.exe" set "GAME=%%R:\Games\SteamLibrary\steamapps\common\PBZ"
    )
)

if not defined GAME (
    echo   没能自动找到游戏目录。
    echo   在 Steam 里右键游戏 - 管理 - 浏览本地文件，复制打开的文件夹路径：
    set /p "GAME=  游戏根目录: "
)
if defined GAME set "GAME=!GAME:"=!"
if defined GAME if "!GAME:~-1!"=="\" set "GAME=!GAME:~0,-1!"

if not defined GAME goto nogame
if not exist "!GAME!\platform\steam\PBZ.exe" goto nogame

echo   游戏目录：!GAME!
echo.

rem ---------- 游戏是否在运行 ----------
if defined SKIPRUN goto notrunning
tasklist /fi "imagename eq PBZ.exe" 2>nul | findstr /i "PBZ.exe" >nul
if not errorlevel 1 (
    echo   [失败] 游戏正在运行，请先完全退出游戏再安装。
    goto fail
)
:notrunning

rem ---------- 前置组件 ----------
set "HASLOADER="
if exist "!GAME!\ProjectPBZ\PBZModLoader\mods.ini" set "HASLOADER=1"
set "HASUE="
if exist "!GAME!\platform\steam\ue4ss\UE4SS.dll" set "HASUE=1"
echo   检查前置组件：
if defined HASLOADER (echo     PBZModLoader：已安装) else (echo     PBZModLoader：未安装 - 只影响评级徽章)
if defined HASUE (echo     UE4SS：已安装) else (echo     UE4SS：未安装 - 只影响音效和音乐律动)
echo.

rem ---------- 复制文件 ----------
set "DSTRANK=!GAME!\ProjectPBZ\PBZModLoader\mods\StylishRank"
set "DSTAUD=!GAME!\platform\steam\ue4ss\Mods\StylishAudio"

echo   安装 StylishRank（评级徽章）...
robocopy "!PKG!payload\StylishRank" "!DSTRANK!" /E /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto copyfail

echo   安装 StylishAudio（升阶音效）...
robocopy "!PKG!payload\StylishAudio" "!DSTAUD!" /E /XF keys.txt /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto copyfail
if not exist "!DSTAUD!\audio\keys.txt" copy /y "!PKG!payload\StylishAudio\audio\keys.txt" "!DSTAUD!\audio\keys.txt" >nul

rem ---------- 校验 ----------
set "MISS="
if not exist "!DSTRANK!\main.js" set "MISS=!MISS! main.js"
if not exist "!DSTAUD!\Scripts\main.lua" set "MISS=!MISS! main.lua"
if not exist "!DSTAUD!\audio\D.WAV" set "MISS=!MISS! D.WAV"
if defined MISS goto verifyfail

rem ---------- PowerShell 执行策略（音效服务需要） ----------
if not defined HASUE goto ok
set "EP="
for /f "usebackq delims=" %%E in (`powershell -NoProfile -Command "Get-ExecutionPolicy" 2^>nul`) do set "EP=%%E"
if /i "!EP!"=="Restricted" goto epset
if /i "!EP!"=="AllSigned" goto epset
goto ok

:epset
echo.
echo   当前 PowerShell 策略是 !EP!，音效服务可能无法启动。
set /p "ANS=  现在把当前用户策略改成 RemoteSigned？(Y/N): "
if /i not "!ANS!"=="Y" goto epskip
powershell -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force"
echo   已设置。
goto ok

:epskip
echo   已跳过。以后没有升阶音效时，在 PowerShell 里执行一次：
echo     Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

:ok
echo.
echo   安装完成 OK
echo   -----------------------------------------------
echo   评级 mod：!DSTRANK!
echo   音效 mod：!DSTAUD!
echo.
echo   进游戏后：
echo     战斗中打中敌人涨分，右上角出现 D / C / B / A / S / SS / SSS 徽章
echo     升阶时播放音效，徽章会跟着背景音乐的重低音缩放、闪光
echo     按 [ 减小 / ] 增大升阶音量（每次 5%%），面板 5 秒不操作自动收起
echo     音量范围 0~200，100 为标准音量，改键见 audio\keys.txt
echo.
if not defined HASLOADER (
    echo   注意：没装 PBZModLoader，评级徽章不会出现。
    echo         装好 PBZModLoader 后自动生效，不用重装本 mod。
)
if not defined HASUE (
    echo   注意：没装 UE4SS，升阶音效和音乐律动不会出现。
    echo         装好 UE4SS 后如果还不行，请重新运行一次本安装器。
)
echo.
echo   卸载：删除上面两个文件夹即可，不影响游戏原文件。
echo.
goto end

:nopayload
echo   [失败] 安装包不完整：找不到 payload 文件夹，请重新解压整个压缩包。
goto fail

:nogame
echo   [失败] 这个目录下没有 platform\steam\PBZ.exe，不是影之刃零的游戏目录。
goto fail

:copyfail
echo   [失败] 复制文件失败。
echo   如果游戏装在 Program Files 下，请右键本文件 - 以管理员身份运行。
goto fail

:verifyfail
echo   [失败] 以下关键文件没到位：!MISS!
goto fail

:fail
echo.
echo   安装未完成。
:end
echo.
pause
endlocal
