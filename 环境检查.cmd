@echo off
chcp 65001 >nul
title DSH-QQ - Check
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Action Check
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%