@echo off
chcp 65001 >nul
title DSH-QQ 记住密码
setlocal
cd /d "%~dp0"

rem deploy.ps1 不一定跟本脚本同层，从近到远找一遍
set "PS1="
if exist "%~dp0deploy.ps1" set "PS1=%~dp0deploy.ps1"
if not defined PS1 if exist "%~dp0ds-as-nap\_install\deploy.ps1" set "PS1=%~dp0ds-as-nap\_install\deploy.ps1"
if not defined PS1 if exist "%~dp0..\deploy.ps1" set "PS1=%~dp0..\deploy.ps1"
if not defined PS1 if exist "%~dp0..\ds-as-nap\_install\deploy.ps1" set "PS1=%~dp0..\ds-as-nap\_install\deploy.ps1"
if defined PS1 goto run

echo.
echo    找不到 deploy.ps1，先跑一次安装脚本再回来。
echo.
pause
exit /b 1

:run
cls
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action SetCred
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%
