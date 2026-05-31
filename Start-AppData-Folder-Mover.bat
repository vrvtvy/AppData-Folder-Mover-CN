@echo off
setlocal
cd /d "%~dp0"
echo AppData Folder Mover
echo.
echo During large transfers, detailed robocopy progress will be shown in this console.
echo Folder size sorting can also take time for huge folders.
echo Do not close this window while moving files.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Move-AppData-Folder.ps1"
if errorlevel 1 pause
