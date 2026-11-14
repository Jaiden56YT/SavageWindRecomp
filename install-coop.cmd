@echo off
rem The same as "Install BotW Co-op.cmd"; with two files on the line, no window: install-coop.cmd "<base game.nsp>" "<1.9.0 update.nsp>"
rem tools\install_coop.ps1 does the work (its header says what).
setlocal
cd /d "%~dp0"
rem Files downloaded from the internet are marked, and Windows warns about each one it runs: take the mark off
rem this folder's own files first (not extracted\, the game's files).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -File | Unblock-File -ErrorAction SilentlyContinue; Get-ChildItem tools -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
rem The update may replace this file, and cmd reads a batch file as it goes: from here on everything is one
rem block, which cmd reads whole before running it.
(
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install_coop.ps1" %*
    echo.
    pause
    exit /b
)
