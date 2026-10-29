<#
.SYNOPSIS
    升级版安装入口：拉部署脚本 + 插件包，装软件并装看门狗插件。
.DESCRIPTION
    和基础版的区别只有一个：多拉三样东西——
      · plugin\install-plugin.ps1     插件安装器
      · plugin\almost_perfect\*        插件本体
    部署脚本装完软件后会检测 plugin\install-plugin.ps1，看到就直接执行它，
    插件就被装进 AstrBot 了。
.EXAMPLE
    .\install-plus.ps1 -QQ 123456789 -OwnerQQ 844328169
#>
param(
    [string]$QQ = '',
    [string]$OwnerQQ = '',
    [string]$ApiKey = '',
    [string]$Branch = 'main',
    [string]$Repo = 'Hejian7/DSAD'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Say([string]$T, [string]$C = 'Gray') { Write-Host $T -ForegroundColor $C }

$mirrors = @(
    "https://raw.githubusercontent.com/$Repo/$Branch",
    "https://cdn.jsdelivr.net/gh/$Repo@$Branch",
    "https://fastly.jsdelivr.net/gh/$Repo@$Branch",
    "https://ghproxy.net/https://raw.githubusercontent.com/$Repo/$Branch",
    "https://ghfast.top/https://raw.githubusercontent.com/$Repo/$Branch"
)

function Get-Remote([string]$RelPath, [string]$Dest) {
    $dir = Split-Path $Dest -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    foreach ($base in $mirrors) {
        $url = $base.TrimEnd('/') + '/' + $RelPath
        try {
            Say ('    下载 ' + $RelPath + '  ←  ' + ([Uri]$url).Host) 'DarkGray'
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 20
            if ((Get-Item $Dest).Length -gt 0) { return $true }
        } catch {
            Say ('      不通：' + $_.Exception.Message) 'DarkGray'
        }
    }
    return $false
}

$work = Join-Path $env:LOCALAPPDATA 'dsh-qq-deploy\bootstrap'
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }

Say ''
Say '============================================================' 'Cyan'
Say '   DSH-QQ 一键部署（升级版 · 含看门狗插件）' 'Cyan'
Say '============================================================' 'Cyan'
Say ('   工作目录：' + $work) 'DarkGray'
Say ''

# 部署脚本 + 插件包
$files = @(
    'deploy.ps1',
    'plugin/install-plugin.ps1',
    'plugin/almost_perfect/main.py',
    'plugin/almost_perfect/metadata.yaml',
    'plugin/almost_perfect/repair.ps1',
    'plugin/almost_perfect/settings.json',
    'plugin/almost_perfect/README.md'
)

foreach ($f in $files) {
    $dest = Join-Path $work ($f -replace '/', '\')
    if (-not (Get-Remote $f $dest)) {
        Say ('✗ 拉不到 ' + $f) 'Red'
        if ($f -like 'plugin/*') {
            Say '  插件包没拉全，这一版会退化成基础版（软件照装，插件不装）。' 'Yellow'
            break
        }
        exit 1
    }
}

$deploy = Join-Path $work 'deploy.ps1'
Say ''
Say '   开始部署……' 'Green'
Say ''

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $deploy + '"'))
if ($QQ) { $argList += @('-QQ', $QQ) }
if ($OwnerQQ) { $argList += @('-OwnerQQ', $OwnerQQ) }
if ($ApiKey) { $argList += @('-ApiKey', $ApiKey) }

$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -NoNewWindow -PassThru -Wait
exit $proc.ExitCode
