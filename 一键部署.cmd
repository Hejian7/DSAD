@echo off
chcp 65001 >nul
title DSH-QQ - Deploy
setlocal
cd /d "%~dp0"
cls

rem deploy.ps1 不一定跟本脚本同层，从近到远找一遍：
rem   1) 本层                       —— clone 仓库下来直接跑的场景
rem   2) 本层\ds-as-nap\_install\   —— 只拿了安装脚本、装完后的场景
rem   3) 上一层 / 上两层            —— 本脚本被放进子目录、或者目录套了一层的场景
set "PS1="
if exist "%~dp0deploy.ps1" set "PS1=%~dp0deploy.ps1"
if not defined PS1 if exist "%~dp0ds-as-nap\_install\deploy.ps1" set "PS1=%~dp0ds-as-nap\_install\deploy.ps1"
if not defined PS1 if exist "%~dp0..\deploy.ps1" set "PS1=%~dp0..\deploy.ps1"
if not defined PS1 if exist "%~dp0..\ds-as-nap\_install\deploy.ps1" set "PS1=%~dp0..\ds-as-nap\_install\deploy.ps1"
if not defined PS1 if exist "%~dp0..\..\deploy.ps1" set "PS1=%~dp0..\..\deploy.ps1"
if defined PS1 goto run

echo.
echo    找不到 deploy.ps1，这几个位置都看过了：
echo      %~dp0
echo      %~dp0ds-as-nap\_install\
echo      %~dp0..\
echo.
echo    只拿到了「安装-升级版.cmd / 安装-基础版.cmd」的话，双击那个就行，
echo    它会自己把 deploy.ps1 拉下来再跑，不用点这个。
echo.
pause
exit /b 1

:run
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action Deploy
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%
