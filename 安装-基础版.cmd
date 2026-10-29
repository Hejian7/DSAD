@echo off
chcp 65001 >nul
title DSH-QQ 一键部署（基础版）
setlocal

echo.
echo  ============================================================
echo    DSH-QQ 一键部署（基础版）
echo  ============================================================
echo.
echo    正在从 GitHub 获取部署脚本……
echo.

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'; $w=Join-Path $d 'ds-as-nap\_install'; New-Item -ItemType Directory -Force -Path $w | Out-Null; $u=@('https://raw.githubusercontent.com/Hejian7/DSAD/main','https://cdn.jsdelivr.net/gh/Hejian7/DSAD@main','https://ghproxy.net/https://raw.githubusercontent.com/Hejian7/DSAD/main','https://ghfast.top/https://raw.githubusercontent.com/Hejian7/DSAD/main'); if ($env:DSAD_BASE_URL) { $u=@($env:DSAD_BASE_URL) }; $o=Join-Path $w 'deploy.ps1'; $ok=$false; foreach ($m in $u) { try { Invoke-WebRequest -Uri ($m + '/deploy.ps1') -OutFile $o -UseBasicParsing -TimeoutSec 20; if ((Get-Item $o).Length -gt 5000) { $ok=$true; break } } catch { } }; if (-not $ok) { Write-Host 'ERROR: deploy.ps1 download failed' -ForegroundColor Red; exit 1 }; Write-Host ('deploy.ps1 OK -> ' + $o); if ($env:DSAD_NO_RUN) { exit 0 }; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $o -InstallRoot (Join-Path $d 'ds-as-nap'); exit $LASTEXITCODE"

set RESULT=%ERRORLEVEL%
echo.
if not "%RESULT%"=="0" (
    echo    没成功。检查网络后再试一次；也可以手动把 deploy.ps1 放到：
    echo      %~dp0ds-as-nap\_install\
    echo    然后右键用 PowerShell 运行它。
)
echo.
pause
exit /b %RESULT%
