@echo off
setlocal enableextensions
REM Halo Drop - dedicated server setup. Double-click, choose Install, pick the .bat you start the server with.
REM The script, the agent jar and the manual are in the server-agent folder next to this file.
if not exist "%~dp0server-agent\HaloDrop-ServerSetup.ps1" (
    echo [HaloDrop] server-agent\HaloDrop-ServerSetup.ps1 not found next to this file.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0server-agent\HaloDrop-ServerSetup.ps1"
echo.
pause
