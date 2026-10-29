<#
.SYNOPSIS
    DSH-QQ 一键卸载：可以只删 AstrBot、只删 NapCat、只删看门狗插件，或者全删。
.DESCRIPTION
    只删本部署装出来的东西，不动你自己的 QQ 客户端。
    删除前会先停掉相关进程，列清单和体积，再问一次。
.EXAMPLE
    .\uninstall.ps1              # 交互式菜单
    .\uninstall.ps1 -Target all  # 直接全删（仍会确认）
    .\uninstall.ps1 -Target all -Yes   # 不确认，直接删
    .\uninstall.ps1 -Target all -DryRun # 只看会删什么，不动手
#>
param(
    [ValidateSet('ask', 'astrbot', 'napcat', 'plugin', 'all')]
    [string]$Target = 'ask',
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Say([string]$T, [string]$C = 'Gray') { Write-Host $T -ForegroundColor $C }
function Title([string]$T) {
    Say ''
    Say '============================================================' 'Cyan'
    Say ('   ' + $T) 'Cyan'
    Say '============================================================' 'Cyan'
}

# 安装根：本脚本旁边的 ds-as-nap
$AsRoot = Join-Path $PSScriptRoot 'ds-as-nap'
$AbDir = Join-Path $AsRoot 'astrbot'
$NcDir = Join-Path $AsRoot 'napcat'
$PluginDir = Join-Path $AbDir 'data\plugins\almost_perfect'

# 历史遗留位置（老版本装在这些地方）
$Legacy = @(
    (Join-Path $env:LOCALAPPDATA 'dsh-qq-deploy'),
    (Join-Path $env:APPDATA 'uv\tools\astrbot'),
    (Join-Path $env:USERPROFILE '.astrbot_launcher'),
    (Join-Path $env:USERPROFILE 'Desktop\NapCat.Shell.Windows.OneKey'),
    (Join-Path $env:USERPROFILE '.local\bin\astrbot.exe')
)

function Get-DirSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return $item.Length }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    return [double]$m.Sum
}

function Show-Target([string]$Label, [string]$Path) {
    $size = Get-DirSize $Path
    if ($size -lt 0) {
        Say ('   · ' + $Label + '：不存在（' + $Path + '）') 'DarkGray'
        return $false
    }
    Say ('   · ' + $Label + '：{0:N1} MB  {1}' -f ($size / 1MB), $Path)
    return $true
}

# ── 选菜单 ────────────────────────────────────────────────────────────────
if ($Target -eq 'ask') {
    Title 'DSH-QQ 一键卸载'
    Say ''
    Say '   要删除哪些东西？（只删本部署装出来的，不动你自己的 QQ）' 'White'
    Say ''
    Say '   1) 只删 AstrBot（本体 + 配置 + 插件都在里面）'
    Say '   2) 只删 NapCat（含它自带的那份 QQ）'
    Say '   3) 只删看门狗插件 Almost perfect'
    Say '   4) 全删（AstrBot + NapCat + 插件 + 日志缓存，以及历史遗留）'
    Say '   0) 退出'
    Say ''
    do {
        $choice = Read-Host '   输入 1 / 2 / 3 / 4 / 0'
    } until ($choice -match '^[0-4]$')
    switch ($choice) {
        '0' { Say '   已退出，什么都没有改动。' 'Yellow'; exit 0 }
        '1' { $Target = 'astrbot' }
        '2' { $Target = 'napcat' }
        '3' { $Target = 'plugin' }
        '4' { $Target = 'all' }
    }
}

Title ('卸载：' + $Target)

# ── 先停进程 ──────────────────────────────────────────────────────────────
function Stop-NapCatAll {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $false }
    foreach ($p in $procs) { cmd /c ('taskkill /F /T /PID ' + $p.ProcessId) 2>&1 | Out-Null }
    Start-Sleep -Seconds 2
    return $true
}

function Stop-AstrBotAll {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq 'astrbot.exe' -or
            ($_.Name -eq 'python.exe' -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($AbDir, [StringComparison]::OrdinalIgnoreCase))
        })
    if ($procs.Count -eq 0) { return $false }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    return $true
}

# ── 列清单 ────────────────────────────────────────────────────────────────
Say ''
Say '   将要删除：' 'White'
$todo = @()
$needAb = ($Target -eq 'astrbot' -or $Target -eq 'plugin' -or $Target -eq 'all')
$needNc = ($Target -eq 'napcat' -or $Target -eq 'all')

if ($Target -eq 'plugin') {
    if (Show-Target '看门狗插件' $PluginDir) { $todo += @{ Kind = 'dir'; Path = $PluginDir } }
} elseif ($Target -eq 'astrbot') {
    if (Show-Target 'AstrBot（含配置与插件）' $AbDir) { $todo += @{ Kind = 'dir'; Path = $AbDir } }
} elseif ($Target -eq 'napcat') {
    if (Show-Target 'NapCat（含自带 QQ）' $NcDir) { $todo += @{ Kind = 'dir'; Path = $NcDir } }
} else {
    if (Show-Target '整个安装目录' $AsRoot) { $todo += @{ Kind = 'dir'; Path = $AsRoot } }
    foreach ($p in $Legacy) {
        if (Show-Target '历史遗留' $p) { $todo += @{ Kind = 'any'; Path = $p } }
    }
}

if ($todo.Count -eq 0) {
    Say ''
    Say '   没有找到要删的东西，可能已经删过了。' 'Yellow'
    Say ''
    exit 0
}

$total = 0
foreach ($t in $todo) { $s = Get-DirSize $t.Path; if ($s -gt 0) { $total += $s } }
Say ''
Say ('   合计约 {0:N1} MB' -f ($total / 1MB)) 'Yellow'

if ($DryRun) {
    Say ''
    Say '   -DryRun：只看不删，什么都没有改动。' 'Green'
    exit 0
}

if (-not $Yes) {
    Say ''
    $ans = Read-Host '   确认删除吗？这个操作不可撤销 (y/N)'
    if ($ans -notmatch '^[yY]') { Say '   已取消，什么都没有改动。' 'Yellow'; exit 0 }
}

# ── 执行 ──────────────────────────────────────────────────────────────────
Say ''
Say '   正在停止相关进程……' 'DarkGray'
if ($needNc -or $Target -eq 'all') { if (Stop-NapCatAll) { Say '     · 已停掉 NapCat' } }
if ($needAb) { if (Stop-AstrBotAll) { Say '     · 已停掉 AstrBot' } }
Start-Sleep -Seconds 1

$failed = 0
foreach ($t in $todo) {
    try {
        if (Test-Path -LiteralPath $t.Path) {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $t.Path) {
            Say ('   ✗ 没删干净：' + $t.Path) 'Red'
            $failed++
        } else {
            Say ('   √ 已删：' + $t.Path) 'Green'
        }
    } catch {
        Say ('   ✗ 删除失败：' + $t.Path) 'Red'
        Say ('     ' + $_.Exception.Message) 'DarkGray'
        $failed++
    }
}

# 全删时顺手清守护任务
if ($Target -eq 'all') {
    $task = 'DSH-QQ-Watchdog'
    $exists = schtasks /Query /TN $task 2>$null
    if ($LASTEXITCODE -eq 0) {
        schtasks /Delete /TN $task /F 2>&1 | Out-Null
        Say ('   √ 已删除计划任务：' + $task) 'Green'
    }
}

Say ''
if ($failed -eq 0) {
    Say '   卸载完成。' 'Green'
    if ($Target -eq 'all') { Say '   安装目录和进程都没了，可以直接重新跑安装脚本。' 'DarkGray' }
    if ($Target -eq 'astrbot') { Say '   NapCat 还在，重新装 AstrBot 后配置可以复用。' 'DarkGray' }
    if ($Target -eq 'napcat') { Say '   AstrBot 还在，但暂时收不到 QQ 消息（需要重装 NapCat）。' 'DarkGray' }
    if ($Target -eq 'plugin') { Say '   插件删了，看门狗不再工作；重跑带插件的安装包可以装回来。' 'DarkGray' }
} else {
    Say ('  有 ' + $failed + ' 项没删掉，通常是进程还占着文件。' ) 'Yellow'
    Say '  先把 AstrBot / NapCat 的窗口关掉，再重跑一次这个脚本。' 'Yellow'
    exit 1
}
exit 0
