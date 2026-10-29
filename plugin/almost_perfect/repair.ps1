param(
    [Parameter(Mandatory = $true)][string]$NapCatDir,
    [int]$Port = 6199,
    [string]$LogDir = '',
    [int]$TimeoutSec = 120
)

# 退出码约定：
#   0 = 已经重新连上 AstrBot（修复成功）
#   2 = 起来了，但需要扫码（二维码已打开并复制到日志目录）
#   1 = 失败

$ErrorActionPreference = 'Continue'
if (-not $LogDir) { $LogDir = Join-Path $PSScriptRoot 'logs' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir ("repair-$stamp.log")

function Write-Log([string]$Text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Test-Connected {
    return [bool](Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
}

Write-Log 'Almost perfect：开始修复'
Write-Log ("NapCat 目录：" + $NapCatDir)

$boot = Join-Path $NapCatDir 'NapCatWinBootMain.exe'
if (-not (Test-Path $boot)) {
    Write-Log ("找不到主程序：" + $boot)
    exit 1
}

# 1) 先关干净（两个实例抢 QQ 是最常见的“修不好”原因）
$procs = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    Write-Log ("先停掉 " + $procs.Count + " 个 NapCat 进程")
    foreach ($p in $procs) {
        cmd /c ('taskkill /F /T /PID ' + $p.ProcessId) 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 3
}
$left = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
if ($left.Count -gt 0) {
    Write-Log ("还有 " + $left.Count + " 个进程杀不掉")
    exit 1
}

# 2) 拉起来
$qrBefore = $null
$qr = Get-ChildItem $NapCatDir -Recurse -Filter 'qrcode.png' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($qr) { $qrBefore = $qr.LastWriteTime }

try {
    Start-Process -FilePath $boot -WorkingDirectory $NapCatDir | Out-Null
    Write-Log '已拉起 NapCat，等它自动登录并连回来'
} catch {
    Write-Log ("启动失败：" + $_.Exception.Message)
    exit 1
}

# 3) 等结果：连上了算成功；出新二维码算需要扫码
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (Test-Connected) {
        Write-Log '已连上 AstrBot，修复成功'
        exit 0
    }

    $qr = Get-ChildItem $NapCatDir -Recurse -Filter 'qrcode.png' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($qr -and ($qr.LastWriteTime -gt (Get-Date).AddSeconds(-30))) {
        if (-not $qrBefore -or $qr.LastWriteTime -gt $qrBefore) {
            $copy = Join-Path $LogDir ("qrcode-$stamp.png")
            try { Copy-Item $qr.FullName $copy -Force } catch { }
            try { Start-Process -FilePath $qr.FullName } catch { }
            Write-Log '需要扫码登录，二维码已打开并复制到日志目录'
            exit 2
        }
    }

    if (-not (Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)) {
        Write-Log 'NapCat 进程起来后又没了'
        exit 1
    }
    Start-Sleep -Milliseconds 1500
}

Write-Log ('等了 ' + $TimeoutSec + ' 秒还没连上')
exit 1
