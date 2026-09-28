@echo off
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%pinger.ps1"
echo.
echo Pinger stopped. Press any key to close this window.
pause >nul
