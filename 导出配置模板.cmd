@echo off
chcp 65001 >nul
title DSH-QQ 导出配置模板
setlocal
cd /d "%~dp0"

rem 从本机已调好的 AstrBot 配置里导出模板，脱敏后写到仓库的 templates 目录。
rem 下次客户部署就会用这份模板初始化，装完直接是"能聊"的状态。

set "CFG=%~dp0ds-as-nap\astrbot\data\cmd_config.json"
set "OUT=%~dp0..\DSAD\templates\cmd_config.template.json"
if exist "%~dp0templates" set "OUT=%~dp0templates\cmd_config.template.json"

if not exist "%CFG%" goto nocfg

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $cfg='%CFG%'; $out='%OUT%'; $j=Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.provider_sources) { try { $p.api_key='' } catch { } }; if ($j.dashboard) { $j.dashboard.password=''; $j.dashboard.pbkdf2_password=''; $j.dashboard.password_storage_upgraded=$false }; $j.admins_id=@(); $j.platform=@(); $d=Split-Path $out -Parent; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; [IO.File]::WriteAllText($out, ($j | ConvertTo-Json -Depth 40), (New-Object Text.UTF8Encoding($false))); Write-Host ('  模板已导出: ' + $out) -ForegroundColor Green; Write-Host ('  大小: ' + (Get-Item $out).Length + ' 字节') -ForegroundColor Gray; Write-Host ''; Write-Host '  脱敏检查：' -ForegroundColor Cyan; Write-Host ('    api_key   : [' + $j.provider_sources[0].api_key + ']') -ForegroundColor Gray; Write-Host ('    password  : [' + $j.dashboard.password + ']') -ForegroundColor Gray; Write-Host ('    admins_id : [' + ($j.admins_id -join ',') + ']') -ForegroundColor Gray; Write-Host ('    provider  : ' + $j.provider[0].id) -ForegroundColor Gray; Write-Host ('    persona   : ' + $(if ($j.persona) { '有（' + $j.persona.PSObject.Properties.Name.Count + ' 项）' } else { '空' })) -ForegroundColor Gray"

echo.
echo    导出完成。别忘了把它推到 GitHub，客户才拿得到：
echo      cd "%~dp0..\DSAD"
echo      git add templates\cmd_config.template.json
echo      git commit -m "更新配置模板"
echo      git push
echo.
pause
exit /b 0

:nocfg
echo.
echo    找不到 AstrBot 配置：%CFG%
echo    先装一次、把 AstrBot 跑起来，再回来导出。
echo.
pause
exit /b 1
