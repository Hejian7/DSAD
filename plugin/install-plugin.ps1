<#
.SYNOPSIS
    Almost perfect 插件的安装器（选装件，由升级版安装包带下来）
.DESCRIPTION
    部署脚本 deploy.ps1 会在装完软件之后检查本文件是否存在：
      · 存在  → 直接调用它 → 插件被装进 AstrBot
      · 不存在 → 基础版，跳过，什么都不装

    这样"买基础款还是升级版"就只是"包里有没有这个文件"，部署脚本本身不用分支。
.PARAMETER AstrBotDataDir
    AstrBot 的 data 目录（启动器形态是 core\data，CLI 形态是 data）
.PARAMETER NapCatRoot
    NapCat 根目录，写进插件配置
.PARAMETER Port
    AstrBot 的 OneBot 端口
.PARAMETER Owner
    主人 QQ，写进插件配置（可为空）
#>
param(
    [Parameter(Mandatory = $true)][string]$AstrBotDataDir,
    [string]$NapCatRoot = '',
    [int]$Port = 6199,
    [string]$Owner = '',
    [string]$SourceDir = ''
)

$ErrorActionPreference = 'Stop'

function Say([string]$T, [string]$C = 'Gray') { Write-Host $T -ForegroundColor $C }

if (-not $SourceDir) { $SourceDir = Join-Path $PSScriptRoot 'almost_perfect' }
if (-not (Test-Path $SourceDir)) {
    Say ('  ! 插件文件不在这里：' + $SourceDir) 'Yellow'
    exit 1
}
if (-not $AstrBotDataDir) {
    Say '  ! 没给 AstrBot 的 data 目录' 'Yellow'
    exit 1
}

$dst = Join-Path $AstrBotDataDir 'plugins\almost_perfect'
$cfgPath = Join-Path $dst 'settings.json'

# 重装时保住客户改过的设置
$oldCfg = $null
if (Test-Path $cfgPath) {
    try { $oldCfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

try {
    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Copy-Item (Join-Path $SourceDir '*') -Destination $dst -Recurse -Force
} catch {
    Say ('  ! 复制插件失败：' + $_.Exception.Message) 'Yellow'
    exit 1
}

# 插件里的 .ps1 必须带 UTF-8 BOM，否则 PS 5.1 按 GBK 读会语法崩
foreach ($ps1 in @(Get-ChildItem $dst -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    try {
        $b = [System.IO.File]::ReadAllBytes($ps1.FullName)
        if ($b.Length -gt 2 -and -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
            $txt = [System.Text.Encoding]::UTF8.GetString($b).TrimStart([char]0xFEFF)
            [System.IO.File]::WriteAllText($ps1.FullName, $txt, [System.Text.UTF8Encoding]::new($true))
            Say ('  · 已给 ' + $ps1.Name + ' 补上 UTF-8 BOM') 'DarkGray'
        }
    } catch { }
}

function Set-Prop($Obj, [string]$Name, $Value) {
    if ($null -eq $Obj) { return }
    $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

$cfg = $oldCfg
if (-not $cfg) {
    $cfg = [pscustomobject]@{
        enabled = $true; napcat_dir = ''; onebot_port = 6199; owner_qq = ''
        check_interval_sec = 60; max_repair_per_hour = 3
        backoff_seconds = @(30, 120, 300, 900); repair_script = 'repair.ps1'
    }
}
if ($NapCatRoot) { Set-Prop $cfg 'napcat_dir' $NapCatRoot }
Set-Prop $cfg 'onebot_port' $Port
if ($Owner) { Set-Prop $cfg 'owner_qq' $Owner }
if (-not ($cfg.PSObject.Properties.Name -contains 'enabled')) { Set-Prop $cfg 'enabled' $true }

$json = $cfg | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($cfgPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

Say ('  √ 插件已装入：' + $dst) 'Green'
Say ('  √ 看门狗：每 ' + [int]$cfg.check_interval_sec + ' 秒查一次，每小时最多修 ' + [int]$cfg.max_repair_per_hour + ' 次') 'Green'
Say '  · 重启 AstrBot 后生效；QQ 里发 /ap 可以看状态' 'DarkGray'
exit 0
