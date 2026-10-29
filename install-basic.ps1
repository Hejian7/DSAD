<#
.SYNOPSIS
    基础版安装入口：从 GitHub 拉部署脚本，装软件（AstrBot + NapCat）。
.DESCRIPTION
    这个脚本本身很小，只做三件事：
      1. 从 GitHub 把 deploy.ps1 拉下来（GitHub 不通就走 ghproxy 镜像）
      2. 放好目录结构
      3. 执行它

    基础版**不带插件**，所以部署脚本里检测不到 plugin\install-plugin.ps1，
    自然不会安装任何插件。
.EXAMPLE
    .\install-basic.ps1 -QQ 123456789 -OwnerQQ 844328169
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

# 每个文件依次试这些源：先直连，再两个 GitHub 加速镜像
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

$work = Join-Path $PSScriptRoot 'ds-as-nap\_install'
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }

Say ''
Say '============================================================' 'Cyan'
Say '   DSH-QQ 一键部署（基础版）' 'Cyan'
Say '============================================================' 'Cyan'
Say ('   工作目录：' + $work) 'DarkGray'
Say ''

# 基础版只拉部署脚本
$files = @('deploy.ps1')
foreach ($f in $files) {
    if (-not (Get-Remote $f (Join-Path $work $f))) {
        Say ('✗ 拉不到 ' + $f + '：检查网络，或手动从 GitHub 下载放到 ' + $work) 'Red'
        exit 1
    }
}

$deploy = Join-Path $work 'deploy.ps1'
Say ''
Say '   开始部署……' 'Green'
Say ''

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $deploy + '"'))
# 告诉部署脚本"安装根在上一层"：不然它会按自己所在的 _install\ 再套一层 ds-as-nap\
$argList += @('-InstallRoot', ('"' + (Join-Path $PSScriptRoot 'ds-as-nap') + '"'))
if ($QQ) { $argList += @('-QQ', $QQ) }
if ($OwnerQQ) { $argList += @('-OwnerQQ', $OwnerQQ) }
if ($ApiKey) { $argList += @('-ApiKey', $ApiKey) }

$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -NoNewWindow -PassThru -Wait
exit $proc.ExitCode
