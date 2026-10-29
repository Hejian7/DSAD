@echo off
chcp 65001 >nul
title DSH-QQ 一键卸载
cd /d "%~dp0"
cls

rem 优先用本地的 deploy.ps1（仓库里、或装完后的 ds-as-nap\_install\）
set "PS1=%~dp0deploy.ps1"
if not exist "%PS1%" set "PS1=%~dp0ds-as-nap\_install\deploy.ps1"

if exist "%PS1%" goto run

rem 都没有，就从 GitHub 拉一份再卸（装卸载逻辑在 deploy.ps1 -Uninstall 里）
echo   本地没有 deploy.ps1，正在从 GitHub 获取……
set "PS1=%TEMP%\dsad-uninstall-deploy.ps1"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$o=$env:TEMP+'\dsad-uninstall-deploy.ps1'; $b=@('https://raw.githubusercontent.com/Hejian7/DSAD/main','https://cdn.jsdelivr.net/gh/Hejian7/DSAD@main','https://ghproxy.net/https://raw.githubusercontent.com/Hejian7/DSAD/main'); foreach($x in $b){ try{ Invoke-WebRequest ($x+'/deploy.ps1') -OutFile $o -UseBasicParsing -TimeoutSec 20; break }catch{} }; if(-not (Test-Path $o)){ exit 1 }"
if errorlevel 1 (
  echo.
  echo   拉取失败：检查网络，或手动把 deploy.ps1 放到本目录再双击。
  pause
  exit /b 1
)

:run
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Uninstall %*
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%
