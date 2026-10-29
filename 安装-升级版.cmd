@echo off
chcp 65001 >nul
title DSH-QQ 一键部署（升级版 · 含看门狗插件）
cd /d "%~dp0"
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-plus.ps1" %*
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%
