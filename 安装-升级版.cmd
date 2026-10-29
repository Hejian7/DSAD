@echo off
chcp 65001 >nul
title DSH-QQ 一键部署（升级版 · 含看门狗插件）
setlocal

echo.
echo  ============================================================
echo    DSH-QQ 一键部署（升级版 · 含看门狗插件）
echo  ============================================================
echo.
echo    正在从 GitHub 获取部署脚本和插件……
echo.

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'; $w=Join-Path $d 'ds-as-nap\_install'; New-Item -ItemType Directory -Force -Path $w | Out-Null; $u=@('https://raw.githubusercontent.com/Hejian7/DSAD/main','https://cdn.jsdelivr.net/gh/Hejian7/DSAD@main','https://ghproxy.net/https://raw.githubusercontent.com/Hejian7/DSAD/main','https://ghfast.top/https://raw.githubusercontent.com/Hejian7/DSAD/main'); if ($env:DSAD_BASE_URL) { $u=@($env:DSAD_BASE_URL) }; $files=@('deploy.ps1','plugin/install-plugin.ps1','plugin/almost_perfect/main.py','plugin/almost_perfect/metadata.yaml','plugin/almost_perfect/repair.ps1','plugin/almost_perfect/settings.json','plugin/almost_perfect/README.md'); $fail=@(); foreach ($f in $files) { $dest=Join-Path $w ($f -replace '/','\'); $dir=Split-Path $dest -Parent; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $got=$false; foreach ($m in $u) { try { Invoke-WebRequest -Uri ($m + '/' + $f) -OutFile $dest -UseBasicParsing -TimeoutSec 20; if ((Get-Item $dest).Length -gt 0) { $got=$true; break } } catch { } }; if (-not $got) { $fail += $f } }; if ($fail.Count -gt 0) { Write-Host ('ERROR: download failed: ' + ($fail -join ', ')) -ForegroundColor Red; exit 1 }; Write-Host ('files OK -> ' + $w); if ($env:DSAD_NO_RUN) { exit 0 }; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $w 'deploy.ps1') -InstallRoot (Join-Path $d 'ds-as-nap'); exit $LASTEXITCODE"

set RESULT=%ERRORLEVEL%
echo.
if not "%RESULT%"=="0" (
    echo    没成功。检查网络后再试一次。
)
echo.
pause
exit /b %RESULT%