@echo off
rem Sets up Savage Wind with the BotW co-op mod: a window asks for your game, update and keys.
rem tools\install_coop.ps1 does the work (its header says what).
setlocal
cd /d "%~dp0"
rem Files downloaded from the internet are marked, and Windows warns about each one it runs: take the mark off
rem this folder's own files first (not extracted\, the game's files).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -File | Unblock-File -ErrorAction SilentlyContinue; Get-ChildItem tools -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
rem The update may replace this file, and cmd reads a batch file as it goes: from here on everything is one
rem block, which cmd reads whole before running it.
(
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install_coop.ps1" 
    echo.
    pause
    exit /b
)
