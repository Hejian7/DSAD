@echo off
chcp 65001 >nul
title DSH-QQ - Start
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Action Start
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%