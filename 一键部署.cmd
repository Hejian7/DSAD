@echo off
chcp 65001 >nul
title DSH-QQ - Deploy
cd /d "%~dp0"
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Action Deploy
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%