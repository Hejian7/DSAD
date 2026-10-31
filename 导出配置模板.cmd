@echo off
chcp 65001 >nul
title DSH-QQ 导出配置模板
setlocal
cd /d "%~dp0"

rem 把本机调好的 AstrBot 状态 → 导出成模板 → 自动推到 GitHub。
rem 导出两样：
rem   templates\cmd_config.template.json   （模型、参数）
rem   templates\personas.json              （人格，在 data_v4.db 的 personas 表里）
rem 都脱敏：api_key / 面板密码 / QQ 号 / 平台 全部清掉。

set "ADATA=%~dp0ds-as-nap\astrbot\data"
set "CFG=%ADATA%\cmd_config.json"
set "DB=%ADATA%\data_v4.db"
set "PY=%~dp0ds-as-nap\astrbot\.venv\Scripts\python.exe"
set "REPO=%~dp0..\DSAD"
set "TPLDIR=%REPO%\templates"

if not exist "%CFG%" goto nocfg
if not exist "%PY%" goto nopy

echo.
echo   [1/3] 导出配置（cmd_config.json）...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $j=Get-Content '%CFG%' -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.provider_sources) { try { $p.api_key='' } catch { } }; if ($j.dashboard) { $j.dashboard.password=''; $j.dashboard.pbkdf2_password=''; $j.dashboard.password_storage_upgraded=$false }; $j.admins_id=@(); $j.platform=@(); if (-not (Test-Path '%TPLDIR%')) { New-Item -ItemType Directory -Path '%TPLDIR%' -Force | Out-Null }; [IO.File]::WriteAllText('%TPLDIR%\cmd_config.template.json', ($j | ConvertTo-Json -Depth 40), (New-Object Text.UTF8Encoding($false))); Write-Host ('      OK  ' + (Get-Item '%TPLDIR%\cmd_config.template.json').Length + ' 字节') -ForegroundColor Green"
if errorlevel 1 goto failed

echo.
echo   [2/3] 导出人格（data_v4.db 的 personas 表）...
set "PYTMP=%TEMP%\dsh-export-persona.py"
>"%PYTMP%" echo import sqlite3, json, sys
>>"%PYTMP%" echo db, out = sys.argv[1], sys.argv[2]
>>"%PYTMP%" echo c = sqlite3.connect(db)
>>"%PYTMP%" echo c.row_factory = sqlite3.Row
>>"%PYTMP%" echo rows = [dict(r) for r in c.execute("select * from personas")]
>>"%PYTMP%" echo for r in rows:
>>"%PYTMP%" echo     r.pop("id", None)
>>"%PYTMP%" echo open(out, "w", encoding="utf-8").write(json.dumps(rows, ensure_ascii=False, indent=2))
>>"%PYTMP%" echo print("      OK  " + str(len(rows)) + " personas")
"%PY%" "%PYTMP%" "%DB%" "%TPLDIR%\personas.json"
set "PYRC=%ERRORLEVEL%"
del "%PYTMP%" 2>nul
if not "%PYRC%"=="0" goto failed

echo.
echo   [3/3] 推送到 GitHub ...
cd /d "%REPO%"
git add templates\cmd_config.template.json templates\personas.json
git commit -m "chore: 更新配置模板" -q
if errorlevel 1 echo      （没有变化，跳过提交）
git push
if errorlevel 1 goto pushfail

echo.
echo    搞定了。客户下次装就会用这份模板。
echo.
pause
exit /b 0

:nocfg
echo.
echo    找不到 AstrBot 配置：%CFG%
echo    先装一次、让 AstrBot 跑起来，再回来导出。
echo.
pause
exit /b 1

:nopy
echo.
echo    找不到 AstrBot 的 python：%PY%
echo    先跑一次「启动.cmd」，让它把环境准备好。
echo.
pause
exit /b 1

:failed
echo.
echo    导出失败，看上面的报错。
echo.
pause
exit /b 1

:pushfail
echo.
echo    导出成功了，但推送失败。
echo    检查网络或 GitHub 凭据，然后手动跑：
echo      cd "%REPO%"
echo      git push
echo.
pause
exit /b 1
