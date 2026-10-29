@echo off
chcp 65001 >nul
title DSH-QQ 一键卸载
cd /d "%~dp0"
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%
