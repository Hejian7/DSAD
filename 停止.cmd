@echo off
chcp 65001 >nul
title DSH-QQ - Stop
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Action Stop
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%