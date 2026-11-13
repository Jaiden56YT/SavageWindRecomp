@echo off
rem One command for Savage Wind with the BotW co-op mod (this fork, branch coop-mods):
rem
rem   install-coop.cmd "C:\path\to\base game.nsp" "C:\path\to\1.9.0 update.nsp"
rem
rem 1. installs the build tools if they aren't there yet (tools\setup_windows.ps1: MSYS2, Python 3.12)
rem 2. downloads the newest co-op mod release from https://github.com/Jaiden56YT/botw-coop
rem 3. runs its setup: reads your own dump into extracted\ (about 15 GB), builds the mod's game files,
rem    puts the mod in and builds Savage Wind with it (15-20 minutes the first time)
rem
rem Run it again to update to a newer co-op release (the dump files can be left out once extracted\ is there).
setlocal
cd /d "%~dp0"

if not exist "C:\msys64\usr\bin\bash.exe" goto tools
if not exist "tools\venv\Scripts\python.exe" goto tools
goto mod

:tools
echo == Installing the build tools (once; this takes a while)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup_windows.ps1
if errorlevel 1 (
  echo Installing the build tools failed: see the messages above.
  exit /b 1
)

:mod
echo == Downloading the newest co-op mod release
if exist "coop\package" rmdir /s /q "coop\package"
mkdir "coop\package" 2>nul
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Jaiden56YT/botw-coop/releases/latest/download/botw-coop-windows-x64.zip' -OutFile 'coop\package\mod.zip'; Expand-Archive -Force 'coop\package\mod.zip' 'coop\package'"
if errorlevel 1 (
  echo Downloading the co-op mod failed. Check the internet connection, or download botw-coop-windows-x64.zip
  echo from https://github.com/Jaiden56YT/botw-coop/releases yourself and run its setup.bat with --recomp "%CD%".
  exit /b 1
)
type "coop\package\botw-coop\VERSION"

echo == Setting up the co-op mod
rem (Python 3.12 from tools\setup_windows.ps1: a window opened before it was installed doesn't have it on PATH)
set "PATH=%LOCALAPPDATA%\Programs\Python\Launcher;%LOCALAPPDATA%\Programs\Python\Python312;%PATH%"
call "coop\package\botw-coop\setup.bat" %* --no-ryujinx --recomp "%CD%"
if errorlevel 1 exit /b 1
echo.
echo Start the game with play-coop.cmd in this folder.
endlocal
