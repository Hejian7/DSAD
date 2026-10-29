@echo off
chcp 65001 >nul
title DSH-QQ 一键卸载
setlocal

cd /d "%~dp0"
cls

rem 优先用本地的 deploy.ps1（仓库里，或装完后的 ds-as-nap\_install\）
set "PS1=%~dp0deploy.ps1"
if not exist "%PS1%" set "PS1=%~dp0ds-as-nap\_install\deploy.ps1"
if exist "%PS1%" goto run

echo.
echo    本地没有 deploy.ps1，正在从 GitHub 获取……
echo.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'; $w=Join-Path $d 'ds-as-nap\_install'; New-Item -ItemType Directory -Force -Path $w | Out-Null; $u=@('https://raw.githubusercontent.com/Hejian7/DSAD/main','https://cdn.jsdelivr.net/gh/Hejian7/DSAD@main','https://ghproxy.net/https://raw.githubusercontent.com/Hejian7/DSAD/main','https://ghfast.top/https://raw.githubusercontent.com/Hejian7/DSAD/main'); if ($env:DSAD_BASE_URL) { $u=@($env:DSAD_BASE_URL) }; $o=Join-Path $w 'deploy.ps1'; $ok=$false; foreach ($m in $u) { try { Invoke-WebRequest -Uri ($m + '/deploy.ps1') -OutFile $o -UseBasicParsing -TimeoutSec 20; if ((Get-Item $o).Length -gt 5000) { $ok=$true; break } } catch { } }; if (-not $ok) { Write-Host 'ERROR: deploy.ps1 download failed' -ForegroundColor Red; exit 1 }"
if errorlevel 1 (
    echo    拉取失败：检查网络，或手动把 deploy.ps1 放到本目录再双击。
    echo.
    pause
    exit /b 1
)
set "PS1=%~dp0ds-as-nap\_install\deploy.ps1"

:run
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Uninstall -InstallRoot "%~dp0ds-as-nap" %*
set RESULT=%ERRORLEVEL%
echo.
pause
exit /b %RESULT%