@echo off
rem Updates the BotW co-op mod (and, if you tick it, Savage Wind) from GitHub and builds the game again.
rem tools\install_coop.ps1 does the work (its header says what).
setlocal
cd /d "%~dp0"
rem Files downloaded from the internet are marked, and Windows warns about each one it runs: take the mark off
rem this folder's own files first (not extracted\, the game's files).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -File | Unblock-File -ErrorAction SilentlyContinue; Get-ChildItem tools -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
rem The update may replace this file, and cmd reads a batch file as it goes: from here on everything is one
rem block, which cmd reads whole before running it.
(
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install_coop.ps1" -Update
    echo.
    pause
    exit /b
)
