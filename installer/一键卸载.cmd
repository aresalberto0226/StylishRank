@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 936 >nul
title StylishRank 一键卸载
set "PKG=%~dp0"
cd /d "!PKG!"

set "GAME="
set "SKIPRUN="
set "YES="
:parseargs
if "%~1"=="" goto argsdone
if /i "%~1"=="--allow-running" (
    set "SKIPRUN=1"
    shift
    goto parseargs
)
if /i "%~1"=="--yes" (
    set "YES=1"
    shift
    goto parseargs
)
set "GAME=%~1"
shift
goto parseargs
:argsdone

echo.
echo   StylishRank - Phantom Blade Zero
echo   影之刃零 DMC5 风格评级  一键卸载
echo.

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
    echo   [失败] 游戏正在运行，请先完全退出游戏再卸载。
    goto fail
)
:notrunning

set "DSTRANK=!GAME!\ProjectPBZ\PBZModLoader\mods\StylishRank"
set "DSTAUD=!GAME!\platform\steam\ue4ss\Mods\StylishAudio"
set "DSTGEN=!GAME!\ProjectPBZ\Content\JavaScript\PBZModLoader\generated-mods\StylishRank"

set "FOUND="
echo   发现以下已安装内容：
if exist "!DSTRANK!" (
    set "FOUND=1"
    echo     评级 mod：!DSTRANK!
)
if exist "!DSTAUD!" (
    set "FOUND=1"
    echo     音效 mod：!DSTAUD!
)
if exist "!DSTGEN!" (
    set "FOUND=1"
    echo     加载器缓存：!DSTGEN!
)
echo.

if not defined FOUND (
    echo   没有发现已安装的 StylishRank / StylishAudio，无需卸载。
    goto end
)

echo   注意：audio\keys.txt 和 audio\volume.txt 里的自定义按键、音量会一起删除。
if defined YES goto dodelete
set /p "ANS=  确认卸载？(Y/N): "
if /i not "!ANS!"=="Y" goto cancel

:dodelete
echo.
echo   正在删除...
rd /s /q "!DSTRANK!" 2>nul
rd /s /q "!DSTAUD!" 2>nul
rd /s /q "!DSTGEN!" 2>nul

set "LEFT="
if exist "!DSTRANK!" set "LEFT=1"
if exist "!DSTAUD!" set "LEFT=1"
if exist "!DSTGEN!" set "LEFT=1"
if defined LEFT goto delpartial

echo.
echo   卸载完成 OK
echo   -----------------------------------------------
echo   已删除：评级 mod、音效 mod、加载器缓存副本。
echo   其他 mod 和游戏原始文件都没有改动。
echo   想再装回来，重新运行「一键安装.cmd」即可。
echo.
goto end

:cancel
echo.
echo   已取消，什么都没删。
goto end

:delpartial
echo.
echo   [失败] 有文件删不掉，可能是被占用（游戏没退干净或音频服务还在运行）。
echo   请完全退出游戏，等 10 秒后再试；还不行就重启电脑。
goto fail

:nogame
echo   [失败] 这个目录下没有 platform\steam\PBZ.exe，不是影之刃零的游戏目录。
goto fail

:fail
echo.
echo   卸载未完成。
:end
echo.
pause
endlocal
