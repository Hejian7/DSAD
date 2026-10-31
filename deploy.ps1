<#
.SYNOPSIS
    DSH / 大肥鱼 QQ 机器人一键部署（Windows）
.DESCRIPTION
    全程脚本，不开 GUI：
      1) 检查环境
      2) 没装 AstrBot 就在 ds-as-nap\astrbot 里建独立环境装（PyPI 镜像，不走 GitHub）
      3) 建工作目录、astrbot init、写 OneBot 平台（端口 + token）、模型、管理员
      4) astrbot run 起服务，等 6199 端口
      5) 定位 NapCat，把它那条反向 WS 客户端指向这台 AstrBot
      6) 重启 NapCat、等扫码、等两端握手
      7) 自检 + 可选守护任务
.NOTES
    AstrBot 的两种形态都认：
      · CLI 安装（ds-as-nap\astrbot\.venv）—— 工作目录里 data\cmd_config.json
      · 启动器安装 —— 实例目录里 core\data\cmd_config.json
    重复运行安全：已有端口/token 一律沿用。
.EXAMPLE
    .\deploy.ps1 -QQ 123456789 -ApiKey sk-xxx
.EXAMPLE
    .\deploy.ps1 -Probe
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$QQ,
    [string]$Model = 'deepseek-flash',
    [string]$InstallRoot = '',
    [ValidateSet('auto', 'cli', 'launcher')]
    [string]$Mode = 'auto',
    [string]$AstrBotDir,
    [string]$WorkDir,
    [string]$NapCatDir,
    [int]$OneBotPort = 6199,
    [ValidateSet('auto', 'onekey', 'shell')]
    [string]$NapCatMode = 'auto',
    [ValidateSet('china', 'official')]
    [string]$DownloadSource = 'china',
    [ValidateSet('Deploy', 'Check', 'Start', 'Stop', 'Status', 'Backup', 'Logs', 'SetCred')]
    [string]$Action = 'Deploy',
    [switch]$SelfCheck,
    [switch]$Probe,
    [switch]$Group,
    [string]$WakeWord = '小五',
    [string]$GroupId = '',
    [string]$OwnerQQ = '',
    [switch]$KeepNapCatRunning,
    [switch]$InstallWatchdog,
    [switch]$SkipNetworkCheck,
    [switch]$Preflight,
    [switch]$Uninstall,
    [ValidateSet('ask', 'astrbot', 'napcat', 'plugin', 'all')]
    [string]$UninstallTarget = 'ask',
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Quiet,
    [string]$EntryKey = ''
)

$ErrorActionPreference = 'Stop'

# ── 入口口令 ───────────────────────────────────────────────────────────────
# 安装-*.cmd / 一键部署.cmd 这些入口会带着它来调本脚本。
# 先说清它的分量：挡不住真想用的人——脚本就躺在客户机器上，打开就能看见这一行。
# 它只把"顺手抄一份去用"变成"得先翻代码找口令"，对防随手白嫖够用了。
# 只拦「部署」：查状态、启动、停止照常跑，免得哪个入口漏传口令把自己锁死。
$script:EntryKeyExpected = 'DSH-QQ-7f3a9c2e'

# 注意：这里只能用 Write-Host，不能用 Say —— Say 要等到函数定义那一段才注册，
# 这段跑在它前头。
if ($Action -eq 'Deploy' -and -not $Preflight -and -not $Probe -and -not $SelfCheck -and -not $Uninstall -and $env:DSAD_NO_GATE -ne '1' -and $EntryKey -ne $script:EntryKeyExpected) {
    Write-Host ''
    Write-Host '  ──────────────────────────────────────────────' -ForegroundColor Yellow
    Write-Host '  这个脚本要通过安装入口启动。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  双击「安装-基础版.cmd」或「安装-升级版.cmd」，它们会带着口令来调它。' -ForegroundColor Yellow
    Write-Host '  （真要手动跑，加 -EntryKey 把口令带上。）' -ForegroundColor DarkGray
    Write-Host '  ──────────────────────────────────────────────' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}
# 不用 Write-Progress。它在 chcp 65001 + 中文环境里按"字符数"算宽度，
# 汉字占两格，重绘时擦不干净，结果就是客户看到的文字叠文字。
# 进度一律改成往下滚的一行行文本：难看一点，但任何终端都不糊。
# SilentlyContinue 顺手把 PowerShell 内置 cmdlet 的进度条也一起关掉。
$ProgressPreference = 'SilentlyContinue'

# ── 常量 ───────────────────────────────────────────────────────────────────
$script:AppName = 'DSH-QQ 一键部署'

# 所有东西都装在脚本旁边的 ds-as-nap\ 里，不散落到用户目录：
#   ds-as-nap\astrbot\   AstrBot 本体（独立 venv）+ data
#   ds-as-nap\napcat\    NapCat 一体包
#   ds-as-nap\python\    Python 3.12（只给 AstrBot 用）
#   ds-as-nap\uv\        uv 单个可执行文件
#   ds-as-nap\logs\      日志
# 安装根目录：默认是本脚本旁边的 ds-as-nap\。
# 但入口脚本会把本脚本下到 ds-as-nap\_install\ 里再执行，那时按 $PSScriptRoot 硬拼
# 会套成 _install\ds-as-nap\。所以看见自己在 _install 里就往上退一层——
# 这样不管谁调的、传没传 -InstallRoot，路径都对得上。
if ($InstallRoot) {
    $script:AsRoot = $InstallRoot
} elseif ($PSScriptRoot) {
    $parent = Split-Path $PSScriptRoot -Parent
    if ((Split-Path $PSScriptRoot -Leaf) -eq '_install' -and (Split-Path $parent -Leaf) -eq 'ds-as-nap') {
        $script:AsRoot = $parent
    } else {
        $script:AsRoot = Join-Path $PSScriptRoot 'ds-as-nap'
    }
} else {
    $script:AsRoot = Join-Path (Get-Location).Path 'ds-as-nap'
}
$script:AsRoot = [IO.Path]::GetFullPath($script:AsRoot)
$script:AbDir = Join-Path $script:AsRoot 'astrbot'
$script:NcDir = Join-Path $script:AsRoot 'napcat'
$script:PyDir = Join-Path $script:AsRoot 'python'
$script:UvDir = Join-Path $script:AsRoot 'uv'
$script:Root = $script:AsRoot
$script:LogDir = Join-Path $script:Root 'logs'
$script:LogFile = Join-Path $script:LogDir ('deploy-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:InstallUrl = 'https://docs.astrbot.app/install.ps1'

# 填过的信息（QQ 号 / API Key / QQ 密码）不放在安装目录里：
# 卸载选"全删"会把 ds-as-nap\ 整个端掉，但这些东西是"你的数据"，
# 不是"程序"，得留着——重装一次不用再敲一遍。
$script:DataDir = Join-Path $env:LOCALAPPDATA 'DSH-QQ'

# uv 默认把下载缓存放到 %LOCALAPPDATA%\uv\cache；钉到这里，别散出去
$env:UV_CACHE_DIR = Join-Path $script:AsRoot 'uv-cache'
if (-not $Uninstall -and -not (Test-Path $env:UV_CACHE_DIR)) { New-Item -ItemType Directory -Path $env:UV_CACHE_DIR -Force -ErrorAction SilentlyContinue | Out-Null }

# ── 联网 / 进度 / 中断保护 ────────────────────────────────────────────────
$script:ProxyUrl = $null
$script:Net = @{}
$script:InterruptRequested = $false
$script:CtrlCGuardOn = $false
$script:CtrlCStrikes = 0
$script:GuardLoaded = $false
$script:ConsoleModeOrig = $null
$script:CurrentStage = ''
$script:MarkerFile = Join-Path $script:Root '.install-in-progress.json'
$script:LockFile = Join-Path $script:Root '.deploy.lock'
$script:NapCatCache = $null
$script:QrViewers = @()
$script:TestApiPort = 31777

# 双击两次是最常见的人为事故：两个部署同时改同一份配置，最后谁对谁错说不清
function Enter-DeployLock {
    try {
        if (-not $Uninstall -and -not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
        if (Test-Path $script:LockFile) {
            $raw = (Get-Content $script:LockFile -Raw -ErrorAction SilentlyContinue)
            $oldPid = 0
            if ($raw) { [void][int]::TryParse($raw.Trim(), [ref]$oldPid) }
            if ($oldPid -gt 0 -and $oldPid -ne $PID) {
                $alive = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                if ($alive) {
                    Fail '已经有一个部署在跑着了' ("另一个窗口正在部署（PID $oldPid）。`n等它跑完，或者先把那个窗口关掉再双击。`n（两个进程同时改配置会互相覆盖，所以这里直接拦下）")
                }
            }
        }
        Set-Content -Path $script:LockFile -Value $PID -Encoding ASCII
    } catch { }
}

function Exit-DeployLock {
    try {
        if (Test-Path $script:LockFile) {
            $raw = (Get-Content $script:LockFile -Raw -ErrorAction SilentlyContinue)
            $oldPid = 0
            if ($raw) { [void][int]::TryParse($raw.Trim(), [ref]$oldPid) }
            if ($oldPid -eq $PID) { Remove-Item $script:LockFile -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

function Set-WindowTitle([string]$Text) {
    if ($Quiet) { return }
    try { $Host.UI.RawUI.WindowTitle = 'DSH 部署 · ' + $Text } catch { }
}

# 注意：不要在这里加 `\r` 原地刷新的“进度条”。
# 中文控制台里用 \r 覆写会让双字节字符错位，屏幕上出现重影（如“位位系系统统”），
# 而且上一轮的残留会和新输出糊在一起。进度一律用普通整行输出。

# TLS 1.2/1.3 + 系统代理：老机器上最常见的两类“莫名其妙连不上”
function Initialize-NetClient {
    try {
        $t = [Net.SecurityProtocolType]::Tls12
        if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
            $t = $t -bor [Net.SecurityProtocolType]::Tls13
        }
        [Net.ServicePointManager]::SecurityProtocol = $t
    } catch { }
    try { [Net.ServicePointManager]::DefaultConnectionLimit = 16 } catch { }

    foreach ($k in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($k)
        if ($v) { $script:ProxyUrl = $v; break }
    }
    if (-not $script:ProxyUrl) {
        try {
            $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
                $s = [string]$ie.ProxyServer
                if ($s -notmatch '^[a-z]+://') { $s = 'http://' + $s }
                $script:ProxyUrl = $s
            }
        } catch { }
    }
    if ($script:ProxyUrl) {
        # 注册表里有代理不等于它活着：探一下，死了就丢掉，别让它把整台机器拖成“没网”
        $probe = Test-Endpoint -Url 'https://www.baidu.com' -TimeoutSec 6
        if ($probe.Ok) {
            Info ('检测到系统代理：' + $script:ProxyUrl + '（活着，下载走它）')
        } else {
            $direct = Test-Endpoint -Url 'https://www.baidu.com' -TimeoutSec 6
            $why = '，已改为直连'
            if (-not $direct.Ok) { $why = '，直连也不通' }
            Warn ('系统代理 ' + $script:ProxyUrl + ' 连不通' + $why)
            $script:ProxyUrl = $null
        }
    }
}

# 国内镜像走代理只会更慢：本来几步就到的，非要绕一圈出国再回来，
# 300 MB 能给你拖成半小时。这些域名一律直连，不走系统代理。
# （公司网必须靠代理才能出站的场景除外——那种机器上直连也连不到，下面的重试会兜住。）
$script:DomesticHosts = @(
    'tuna.tsinghua.edu.cn',
    'mirrors.aliyun.com',
    'mirrors.ustc.edu.cn',
    'mirrors.cernet.edu.cn',
    'mirror.nju.edu.cn',
    'mirrors.bfsu.edu.cn',
    'mirrors.huaweicloud.com',
    'mirrors.cloud.tencent.com',
    'npmmirror.com',
    'registry.npmmirror.com',
    'docs.astrbot.app'
)

function Test-DomesticMirror([string]$Url) {
    try {
        $h = ([Uri]$Url).Host
        foreach ($d in $script:DomesticHosts) {
            if ($h -eq $d -or $h.EndsWith('.' + $d, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    } catch { }
    return $false
}

# 给一个请求决定要不要挂代理：境外站点挂，国内镜像不挂
function Set-RequestProxy($Req, [string]$Url) {
    if (-not $script:ProxyUrl) { return }
    if (Test-DomesticMirror $Url) { $Req.Proxy = $null; return }
    $Req.Proxy = New-Object System.Net.WebProxy($script:ProxyUrl, $true)
}

# 注意：这里刻意不用 Invoke-WebRequest 的 splatting（@参数表）。
# 实测在装了安全软件的机器上，`Invoke-WebRequest @p` 会让 PowerShell 5.1
# 无声无息地整个进程退出（退出码 0、无报错），排查成本极高。
# 直接用 HttpWebRequest，行为和超时都可控。
function Test-Endpoint([string]$Url, [int]$TimeoutSec = 5, [switch]$Head, [switch]$NoProxyRetry) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ms = 0
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'DSH-Deploy/1.0'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $true
        if ($Head) { $req.Method = 'HEAD' }
        Set-RequestProxy $req $Url
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        $sw.Stop()
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds; Status = $code; Error = '' }
    } catch [System.Net.WebException] {
        $sw.Stop()
        $ms = [int]$sw.ElapsedMilliseconds
        $we = $_.Exception
        try {
            if ($we.Response) {
                $code = [int]$we.Response.StatusCode
                $we.Response.Close()
                # 4xx/5xx 说明网络是通的，只是这个地址不欢迎 HEAD 或裸访问
                if ($code -ge 200 -and $code -lt 500) {
                    return [pscustomobject]@{ Ok = $true; Ms = $ms; Status = $code; Error = $we.Message }
                }
            }
        } catch { }
        # 代理挂了就改直连再探一次，别让一个死代理把整台机器判成没网
        if ($script:ProxyUrl -and -not $NoProxyRetry) {
            Warn ('走代理连不上，改直连重试：' + $Url)
            $script:ProxyUrl = $null
            return (Test-Endpoint -Url $Url -TimeoutSec $TimeoutSec -Head:$Head -NoProxyRetry)
        }
        return [pscustomobject]@{ Ok = $false; Ms = $ms; Status = 0; Error = $we.Message }
    } catch {
        $sw.Stop()
        if ($script:ProxyUrl -and -not $NoProxyRetry) {
            $script:ProxyUrl = $null
            return (Test-Endpoint -Url $Url -TimeoutSec $TimeoutSec -Head:$Head -NoProxyRetry)
        }
        return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.ElapsedMilliseconds; Status = 0; Error = $_.Exception.Message }
    }
}

# 本地清点：先看这台机器上已经有什么。后面要不要下载、要探哪些站点，全看它。
function Get-LocalInventory {
    Step '1.1' '清点本地已有的东西'

    $inv = [pscustomobject]@{ Uv = $null; Python312 = $null; AstrBot = $null; NapCat = $null; Qq = $null }

    $inv.Uv = Get-UvOnPath
    if ($inv.Uv) { Ok ('uv：已装 ' + $inv.Uv) }
    else { Info 'uv：没有 —— 要用的话从 PyPI 镜像取 wheel（约 20 MB）' }

    $inv.Python312 = Get-Python312Path
    if ($inv.Python312) { Ok ('Python 3.12：已装 ' + $inv.Python312) }
    else { Info 'Python 3.12：没有 —— 需要时下可嵌入版（约 11 MB，不写注册表）' }

    $ab = Resolve-AstrBotExisting
    $inv.AstrBot = $ab
    if ($ab) { Ok ('AstrBot：已装（' + $ab.Kind + '）' + $ab.Root) }
    else { Info 'AstrBot：没装 —— 走 PyPI 镜像直装，不碰 GitHub' }

    $qq = Get-QqClientInfo
    $inv.Qq = $qq

    $nap = Find-NapCat -ExistingOnly
    $inv.NapCat = $nap
    if ($nap) { $script:NapCatCache = $nap; Ok ('NapCat：已有 ' + $nap) }
    elseif ($qq) { Info 'NapCat：没有 —— 机器上已有 QQ，只下 Shell 包（约 34 MB）' }
    else { Info 'NapCat：没有 —— 没找到 QQ 客户端，走一体包（约 34 MB 外壳 + 300 MB QQ）' }

    if ($qq) { Ok ('QQ 客户端：' + $qq.Version + ' @ ' + $qq.Root) }
    else { Info 'QQ 客户端：没检测到（用一体包会自带，不用管）' }

    return $inv
}

# 联网预检：只探「这次真的要下载的那几样」，本地已经有的完全不浪费时间
function Test-NetworkProfile($Inventory) {
    Step '1.2' '联网预检（只查这次要用到的源，每项 3 秒超时）'
    Set-WindowTitle '联网预检'

    $needPypi = $false
    $needPython = $false
    $needNapCat = $false

    if (-not $Inventory.AstrBot) {
        $needPypi = $true
        if (-not $Inventory.Python312) { $needPython = $true }
    }
    if (-not $Inventory.NapCat) { $needNapCat = $true }

    $script:Net = @{}
    $script:Net['pypi_any'] = $true

    if (-not $needPypi -and -not $needPython -and -not $needNapCat) {
        Ok '本地该有的都有，这次一个字节都不用下，跳过联网预检'
        return
    }

    $probes = @()
    if ($needPypi) {
        $probes += [pscustomobject]@{ Key = 'pypi_tuna'; Name = '清华 PyPI'; Url = 'https://pypi.tuna.tsinghua.edu.cn/simple/uv/' }
    }
    if ($needPython) {
        $probes += [pscustomobject]@{ Key = 'python'; Name = 'npmmirror Py3.12'; Url = 'https://registry.npmmirror.com/-/binary/python/3.12.10/python-3.12.10-amd64.exe' }
    }
    if ($needNapCat) {
        $probes += [pscustomobject]@{ Key = 'github'; Name = 'GitHub 直连'; Url = 'https://github.com' }
        $probes += [pscustomobject]@{ Key = 'ghproxy'; Name = 'ghproxy 镜像'; Url = 'https://ghproxy.net' }
        $probes += [pscustomobject]@{ Key = 'ghproxy2'; Name = 'gh-proxy 镜像'; Url = 'https://gh-proxy.com' }
    }

    $pypiFallbackTried = $false
    foreach ($t in $probes) {
        $r = Test-Endpoint -Url $t.Url -TimeoutSec 3 -Head
        $script:Net[$t.Key] = $r.Ok
        if ($r.Ok) {
            Say ("    √ {0,-16} {1,5} ms" -f $t.Name, $r.Ms) 'Green'
        } else {
            Say ("    ! {0,-16} 不通" -f $t.Name) 'Yellow'
            # 主选挂了才试备选，不预先把备选全打一遍
            if ($t.Key -eq 'pypi_tuna' -and -not $pypiFallbackTried) {
                $pypiFallbackTried = $true
                foreach ($b in @(
                        [pscustomobject]@{ Name = '阿里 PyPI'; Url = 'https://mirrors.aliyun.com/pypi/simple/uv/' },
                        [pscustomobject]@{ Name = 'cernet PyPI'; Url = 'https://mirrors.cernet.edu.cn/pypi/web/simple/uv/' }
                    )) {
                    $rb = Test-Endpoint -Url $b.Url -TimeoutSec 3 -Head
                    if ($rb.Ok) {
                        Say ("    √ {0,-16} {1,5} ms（备选）" -f $b.Name, $rb.Ms) 'Green'
                        $script:Net['pypi_tuna'] = $true
                        break
                    }
                    Say ("    ! {0,-16} 不通" -f $b.Name) 'Yellow'
                }
            }
        }
    }

    if ($needPypi -and -not $script:Net['pypi_tuna']) {
        Fail 'PyPI 镜像一个都连不上，装不了 AstrBot' @"
清华、阿里、cernet 都试过了。通常意味着：
  1) 机器根本没联网（先浏览器随便打开一个网页试试）
  2) 公司/校园网要认证或走代理（设好代理后重跑，脚本会自动识别系统代理）
  3) DNS 坏了：换 223.5.5.5 / 119.29.29.29 再试
实在不行，手机开热点给这台机器跑一次。
"@
    }
    if ($needPython -and -not $script:Net['python']) {
        Warn 'npmmirror 连不上：装 Python 3.12 那步可能很慢或者失败'
    }
    if ($needNapCat -and -not $script:Net['github'] -and -not $script:Net['ghproxy'] -and -not $script:Net['ghproxy2']) {
        Warn 'NapCat 的三个源（GitHub 直连 / ghproxy / gh-proxy）都不通：到时候会提示你手动放安装包'
    }
}

# 带进度条的下载：字节级进度 + 重试 + 可选 sha256
function Get-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Label = '',
        [string]$Sha256 = '',
        [int]$MaxRetry = 2,
        [int]$StallTimeoutSec = 90
    )
    if (-not $Label) { $Label = Split-Path $OutFile -Leaf }
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $tmp = $OutFile + '.part'
    for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
        if ($attempt -gt 1) { Info ('重试第 ' + $attempt + ' 次：' + $Label) }
        try {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = 'DSH-Deploy/1.0'
            $req.Timeout = 20000
            $req.ReadWriteTimeout = $StallTimeoutSec * 1000
            Set-RequestProxy $req $Url

            $resp = $req.GetResponse()
            try {
                $total = $resp.ContentLength
                $in = $resp.GetResponseStream()
                $out = [System.IO.File]::Create($tmp)
                $buf = New-Object byte[] 65536
                $done = 0L
                $lastPaint = [DateTime]::MinValue
                $lastPct = -100
                $sw = [Diagnostics.Stopwatch]::StartNew()
                try {
                    while ($true) {
                        if ($script:InterruptRequested) { throw '用户已请求中断' }
                        $n = $in.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { break }
                        $out.Write($buf, 0, $n)
                        $done += $n
                        $now = Get-Date
                        $mb = $done / 1MB
                        $spd = 0.0
                        if ($sw.Elapsed.TotalSeconds -gt 0.5) { $spd = ($done / 1MB) / $sw.Elapsed.TotalSeconds }
                        $pct = -1
                        if ($total -gt 0) { $pct = [int](100 * $done / $total) }

                        # 不原地重绘：中文在那儿擦不干净。每 3 秒、或百分比动了 10 格，
                        # 就老老实实滚一行——客户只要看见数字在变，就知道没卡死。
                        $print = $false
                        if ($pct -ge 0) {
                            if (($now - $lastPaint).TotalSeconds -ge 3 -or ($pct - $lastPct) -ge 10) { $print = $true }
                        } elseif (($now - $lastPaint).TotalSeconds -ge 3) {
                            $print = $true
                        }
                        if ($print) {
                            $lastPaint = $now
                            $lastPct = $pct
                            if (-not $Quiet) {
                                if ($pct -ge 0) {
                                    Write-Host ('      {0,6:N1} / {1:N1} MB   {2,3}%   {3,4:N1} MB/s' -f $mb, ($total / 1MB), $pct, $spd) -ForegroundColor DarkGray
                                } else {
                                    Write-Host ('      {0,6:N1} MB   {1,4:N1} MB/s' -f $mb, $spd) -ForegroundColor DarkGray
                                }
                            }
                            if ($pct -ge 0) { Set-WindowTitle ('下载 ' + $Label + ' ' + $pct + '%') }
                            else { Set-WindowTitle ('下载 ' + $Label + ' ' + ('{0:N1}' -f $mb) + ' MB') }
                        }
                    }
                } finally {
                    $out.Close(); $in.Close()
                }
            } finally {
                $resp.Close()
            }
            if ($total -gt 0 -and $done -ne $total) { throw ('下载不完整（' + $done + '/' + $total + ' 字节）') }
            if ($Sha256) {
                $h = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
                if ($h -ne $Sha256.ToLower()) { throw '文件校验失败（sha256 不匹配）' }
            }
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
            Move-Item $tmp $OutFile -Force
            return $true
        } catch {
            if ($script:InterruptRequested) { throw }
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            # 代理最坑：注册表里配着、进程早死了。显式挂一个死代理会让所有请求全灭。
            if ($script:ProxyUrl) {
                Warn ('连不上，怀疑代理已失效，改为直连重试（' + $_.Exception.Message + '）')
                $script:ProxyUrl = $null
                $attempt = $attempt - 1
                continue
            }
            if ($attempt -eq $MaxRetry) { throw }
            Warn ('下载出错：' + $_.Exception.Message)
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# 多个源轮流试，第一个成功的算数
function Get-FileFromMirrors {
    param([object[]]$Mirrors, [string]$OutFile, [string]$Sha256 = '', [int]$MaxRetry = 2)
    $file = Split-Path $OutFile -Leaf
    foreach ($m in $Mirrors) {
        Info ('下载 {0}  ←  {1}' -f $file, $m.Name)
        Info ('    ' + $m.Url)
        try {
            $null = Get-FileWithProgress -Url $m.Url -OutFile $OutFile -Label $m.Name -Sha256 $Sha256 -MaxRetry $MaxRetry
            Ok ('下载完成（{0:N1} MB，源：{1}）' -f ((Get-Item $OutFile).Length / 1MB), $m.Name)
            return $true
        } catch {
            if ($script:InterruptRequested) { throw }
            Warn ('这个源不行（' + $m.Name + '）：' + $_.Exception.Message)
        }
    }
    return $false
}

# 读日志尾巴：子进程的输出编码跟控制台走（有 chcp 65001 就是 UTF-8，否则 GBK），
# 先按 UTF-8 解码，出现替换字符就说明其实是 GBK，换一种再读。
# 解压 zip。别直接用 Expand-Archive：PS 5.1 那个实现对某些 zip（目录条目和文件条目
# 混排，NapCat 的包就是）会报 "Cannot find path ... because it does not exist"，
# 加 -Force 也救不了。结果就是明明 34 MB 能搞定，被迫退回 300 MB 的一体包。
# 优先用 .NET 的 ZipFile，它稳；真不行再退回 Expand-Archive。
function Expand-ZipSafe([string]$Zip, [string]$Dest) {
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dest)
        return $true
    } catch {
        # 目标目录非空是 ExtractToDirectory 的硬性要求，先清一遍再试一次
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dest, $true)
            return $true
        } catch {
            Warn ('ZipFile 解压失败：' + $_.Exception.Message)
        }
    }
    try {
        Expand-Archive -Path $Zip -DestinationPath $Dest -Force -ErrorAction Stop
        return $true
    } catch {
        Warn ('Expand-Archive 也失败了：' + $_.Exception.Message)
        return $false
    }
}
function Read-LogTail([string]$Path, [int]$Lines = 1) {
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -eq 0) { return @() }
        if ($bytes.Length -gt 131072) {
            $bytes = $bytes[($bytes.Length - 131072)..($bytes.Length - 1)]
        }
        $u8 = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text = $u8
        if ($u8.IndexOf([char]0xFFFD) -ge 0) {
            try { $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes) } catch { }
        }
        return @($text -split "[\r\n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Last $Lines)
    } catch { return @() }
}

# 子进程跑到一半的"进度"，只做一件事：每几秒往下滚一行文字。
# 不再原地重绘——Write-Progress 在中文 + chcp 65001 下擦不干净，会糊成一团。
# 滚动的代价是刷屏，好处是绝对不糊；而且"最后一行一直在变"本身就是最好的存活证明。
# 卡死也照旧换路：StallSec 秒日志一个字没长，直接杀掉让调用方换镜像。
# 返回：真实退出码 / -2 超时 / -3 卡死 / -1 拿不到退出码（未知，交给调用方按副作用判断）
function Wait-ProcessWithProgress {
    param($Process, [string]$Label, [int]$TimeoutSec = 900, [string]$LogPath = '', [int]$StallSec = 0, [int]$BeatSec = 8)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastBeat = -$BeatSec
    $lastMove = 0
    $lastLine = ''

    while (-not $Process.HasExited) {
        if ($script:InterruptRequested) {
            try { $Process.Kill() } catch { }
            throw '用户已请求中断'
        }
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        if ($elapsed -gt $TimeoutSec) {
            try { $Process.Kill() } catch { }
            return -2
        }
        $t = '{0:00}:{1:00}' -f [math]::Floor($elapsed / 60), ($elapsed % 60)
        Set-WindowTitle ($Label + ' ' + $t)

        # 很多工具（uv、npm、pip）把下载进度写 stderr，所以两边都看
        $line = ''
        if ($LogPath) {
            $t1 = @(Read-LogTail -Path ($LogPath + '.err') -Lines 1)
            $t2 = @(Read-LogTail -Path $LogPath -Lines 1)
            if ($t2.Count -gt 0) { $line = [string]$t2[0] }
            if ($t1.Count -gt 0) { $line = [string]$t1[0] }
        }
        if ($line.Length -gt 60) { $line = $line.Substring(0, 60) + '…' }

        # uv 的日志能算出真进度：先 "Resolved 154 packages"，之后每个包一行
        # Downloading / Prepared / Built / Installed。行数是进度，括号里是体积。
        # 这段只在有日志时算（NapCat 安装器那种没有，就别瞎编数字）。
        $mb = 0.0
        $done = 0
        $totalPkgs = 0
        if ($LogPath) {
            $files = @(($LogPath + '.err'), $LogPath)
            $files = @($files | Where-Object { Test-Path $_ })
            foreach ($f in $files) {
                try {
                    $txt = [System.IO.File]::ReadAllText($f)
                    $done += ([regex]::Matches($txt, '(?m)^\s*(Downloading|Prepared|Built|Installed)\s')).Count
                    if ($totalPkgs -eq 0) {
                        $mm = [regex]::Match($txt, 'Resolved (\d+) packages?')
                        if ($mm.Success) { $totalPkgs = [int]$mm.Groups[1].Value }
                    }
                    foreach ($dm in [regex]::Matches($txt, '(?m)^\s*Downloading\s+\S+\s+\(([\d.]+)\s*(KiB|MiB|GiB)\)')) {
                        $v = [double]$dm.Groups[1].Value
                        switch ($dm.Groups[2].Value) {
                            'KiB' { $mb += $v / 1024 }
                            'GiB' { $mb += $v * 1024 }
                            default { $mb += $v }
                        }
                    }
                } catch { }
            }
        }
        if ($line -and $line -ne $lastLine) { $lastLine = $line; $lastMove = $elapsed }

        # 卡死检测：真死掉的连接不会自己好，早点杀掉换源，比干等到总超时强
        if ($StallSec -gt 0 -and $totalPkgs -gt 0 -and ($elapsed - $lastMove) -ge $StallSec) {
            try { $Process.Kill() } catch { }
            return -3
        }

        # 一行，就一行。客户去泡了杯茶回来，看到的是"还在动"，不是一条冻住的东西。
        if (-not $Quiet -and $BeatSec -gt 0 -and ($elapsed - $lastBeat) -ge $BeatSec) {
            $lastBeat = $elapsed
            $beat = '    · ' + $Label + ' 已用 ' + $t
            if ($mb -gt 0) { $beat += (' ｜ 已下 {0:N0} MB' -f $mb) }
            if ($totalPkgs -gt 0) {
                $beat += (' ｜ {0} / {1} 个包' -f [Math]::Min($done, $totalPkgs), $totalPkgs)
            } elseif ($done -gt 0) {
                $beat += (' ｜ 已处理 ' + $done + ' 个包')
            } elseif ($LogPath) {
                if ($LogPath -and (Test-Path $LogPath) -and (Get-Item $LogPath).Length -eq 0) {
                    $beat += ' ｜ 还在跑（这个安装器不打印进度）'
                } else {
                    $beat += ' ｜ 正在解析依赖（这一步慢是常态）'
                }
            }
            if ($line) {
                $short = $line
                if ($short.Length -gt 50) { $short = $short.Substring(0, 50) + '…' }
                $beat += (' ｜ ' + $short)
            }
            if ($totalPkgs -gt 0 -and ($elapsed - $lastMove) -ge 180) { $beat += ' ｜（三分钟没新包：网可能在卡，脚本没死）' }
            Write-Host $beat -ForegroundColor DarkGray
            Write-Log $beat
        }
        Start-Sleep -Milliseconds 900
    }

    # PS 5.1 的坑：Start-Process -PassThru 不配 -Wait 时，ExitCode 常常是 $null
    try { $null = $Process.WaitForExit(5000) } catch { }
    try { $Process.Refresh() } catch { }
    $code = $null
    try { $code = $Process.ExitCode } catch { }
    if ($null -eq $code) { return -1 }
    return [int]$code
}

# ── 中断保护：关窗按钮 + Ctrl+C + 断点标记 ─────────────────────────────────
function Initialize-ConsoleGuard {
    if ($script:GuardLoaded) { return }
    try {
        if (-not ('DSHDeploy.ConsoleGuard' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DSHDeploy {
    public static class ConsoleGuard {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
        [DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
        [DllImport("user32.dll")] public static extern bool DrawMenuBar(IntPtr hWnd);
        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    }
}
'@ -ErrorAction Stop
        }
        $script:GuardLoaded = [bool]('DSHDeploy.ConsoleGuard' -as [type])
    } catch { $script:GuardLoaded = $false }
}

# 安装期间摘掉窗口的关闭按钮：误点 X 关不掉，就不存在“装到一半没了”
function Set-CloseButton([bool]$Enabled) {
    Initialize-ConsoleGuard
    if (-not $script:GuardLoaded) { return }
    try {
        $h = [DSHDeploy.ConsoleGuard]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return }
        if ($Enabled) {
            $null = [DSHDeploy.ConsoleGuard]::GetSystemMenu($h, $true)
        } else {
            $menu = [DSHDeploy.ConsoleGuard]::GetSystemMenu($h, $false)
            $null = [DSHDeploy.ConsoleGuard]::DeleteMenu($menu, 0xF060, 0)
            $null = [DSHDeploy.ConsoleGuard]::DrawMenuBar($h)
        }
    } catch { }
}

# 客户在窗口里手一抖点了一下文字，控制台就进了"选择"模式：所有输出被冻住，
# 程序看着像死了，按个键才活过来——这就是"莫名其妙停了"的真凶，跟网速没关系。
# 把快速编辑关掉，从此点选不会再冻住输出。
function Set-QuickEdit([bool]$Enabled) {
    Initialize-ConsoleGuard
    if (-not $script:GuardLoaded) { return }
    try {
        $h = [DSHDeploy.ConsoleGuard]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr](-1)) { return }
        $mode = [uint32]0
        if (-not [DSHDeploy.ConsoleGuard]::GetConsoleMode($h, [ref]$mode)) { return }
        if ($Enabled) {
            if ($null -ne $script:ConsoleModeOrig) {
                [void][DSHDeploy.ConsoleGuard]::SetConsoleMode($h, [uint32]$script:ConsoleModeOrig)
            }
            return
        }
        $script:ConsoleModeOrig = $mode
        # 清掉 ENABLE_QUICK_EDIT_MODE(0x40)；顺带补上 ENABLE_EXTENDED_FLAGS(0x80)，
        # 不加这一位，某些系统上改了不生效
        $new = [uint32](($mode -band 0xFFFFFFBF) -bor 0x0080)
        if ($new -ne $mode) { [void][DSHDeploy.ConsoleGuard]::SetConsoleMode($h, $new) }
    } catch { }
}

function Enable-CtrlCGuard {
    if ($script:CtrlCGuardOn) { return }
    $script:CtrlCGuardOn = $true
    try {
        [Console]::CancelKeyPress += {
            param($sender, $e)
            $script:CtrlCStrikes = [int]$script:CtrlCStrikes + 1
            if ($script:CtrlCStrikes -ge 2) { $e.Cancel = $false; return }
            $e.Cancel = $true
            $script:InterruptRequested = $true
            Write-Host ''
            Write-Host '  ! 收到 Ctrl+C：这一下不当场杀，先收拾现场。' -ForegroundColor Yellow
            Write-Host '    要强制结束，再按一次 Ctrl+C。' -ForegroundColor Yellow
        }
    } catch { }
}

function Write-RunMarker([string]$Stage) {
    $script:CurrentStage = $Stage
    try {
        if (-not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
        $o = [ordered]@{
            stage = $Stage
            pid   = $PID
            at    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        ($o | ConvertTo-Json) | Set-Content -Path $script:MarkerFile -Encoding UTF8
    } catch { }
}

function Clear-RunMarker {
    Remove-Item $script:MarkerFile -Force -ErrorAction SilentlyContinue
}

function Get-PreviousRun {
    if (-not (Test-Path $script:MarkerFile)) { return $null }
    try { return (Get-Content $script:MarkerFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ── 输出 ───────────────────────────────────────────────────────────────────
function Write-Log([string]$Text) {
    # 卸载时会把自己的安装目录删掉（日志本来就在里面），所以这里必须容错，
    # 不能因为写不进日志就把整个卸载判成失败。
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force -ErrorAction Stop | Out-Null }
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}
function Say([string]$Text, [string]$Color = 'Gray') {
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
    Write-Log $Text
}
function Step([string]$No, [string]$Title) {
    Say ''
    Say ("[{0}] {1}" -f $No, $Title) 'Cyan'
}
function Ok([string]$Text)   { Say ("    √ " + $Text) 'Green' }
function Info([string]$Text) { Say ("    · " + $Text) 'Gray' }
function Warn([string]$Text) { Say ("    ! " + $Text) 'Yellow' }

function Fail([string]$Reason, [string]$Hint = '') {
    Say ''
    Say '──────────────────────────────────────────────' 'Red'
    Say ("✗ 失败：" + $Reason) 'Red'
    if ($Hint -ne '') {
        Say ''
        Say '怎么办：' 'Yellow'
        foreach ($l in ($Hint -split "`n")) { Say ('  ' + $l) 'Yellow' }
    }
    Say ''
    Say ('完整日志：' + $script:LogFile) 'DarkGray'
    Say '──────────────────────────────────────────────' 'Red'
    Write-Log ("FAIL: " + $Reason)
    exit 1
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── 安全软件：这部署干的活，在杀软眼里几乎全是坏事 ──────────────────────────
# 下 exe（uv / Python / QQ）、建 venv、往 QQ 进程里注入、写计划任务。
# 一句话都不说，客户只会看到"卡在 30%""装完 astrbot.exe 不见了"，然后以为脚本坏了。
function Get-SecurityProducts {
    $list = @()
    $seen = @{}

    # 1) 安全中心登记过的：Defender 和用正规安装包装的国产杀软都在这
    try {
        foreach ($a in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            $n = [string]$a.displayName
            if (-not $n -or $seen.ContainsKey($n)) { continue }
            $seen[$n] = $true
            # productState 是个位掩码，0x1000 那一位=实时防护开着（各家实现差不多）
            $psv = 0
            try { $psv = [int]$a.productState } catch { }
            if ($psv -eq 0) {
                $raw = [string]$a.productState
                if ($raw -match '0x([0-9a-fA-F]+)') { try { $psv = [Convert]::ToInt32($matches[1], 16) } catch { } }
            }
            $rt = $true
            if ($psv -gt 0) { $rt = (($psv -band 0x1000) -ne 0) }
            $list += [pscustomobject]@{ Name = $n; RealTime = $rt }
        }
    } catch { }

    # 2) 没在安全中心登记的（绿色版、老版本、只挂后台的），按进程名兜底
    $known = @(
        @{ P = '360tray'; N = '360安全卫士' },
        @{ P = 'ZhuDongFangYu'; N = '360安全卫士' },
        @{ P = 'HipsTray'; N = '火绒' },
        @{ P = 'usysdiag'; N = '火绒' },
        @{ P = 'QQPCTray'; N = '腾讯电脑管家' },
        @{ P = 'kxetray'; N = '金山毒霸' },
        @{ P = 'BaiduSdTray'; N = '百度杀毒' }
    )
    foreach ($k in $known) {
        if ($seen.ContainsKey($k.N)) { continue }
        if (@(Get-Process -Name $k.P -ErrorAction SilentlyContinue).Count -gt 0) {
            $seen[$k.N] = $true
            $list += [pscustomobject]@{ Name = $k.N; RealTime = $true }
        }
    }
    return $list
}

function Test-DefenderRealTime {
    try { return [bool](Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled }
    catch { return $false }
}

# 开场报一次就够了：后面每步都刷一遍，就成了唠叨，客户会直接不看
function Show-SecurityNotice {
    $names = @(Get-SecurityProducts | ForEach-Object { $_.Name })
    $defRt = Test-DefenderRealTime
    if ($defRt -and -not ($names -contains 'Windows Defender')) { $names = @('Windows Defender') + $names }
    if ($names.Count -eq 0) { return }

    Say ('    检测到安全软件：' + ($names -join '、')) 'DarkGray'
    Say '    这套部署要下 exe、建虚拟环境、往 QQ 里注入——杀软常把这些当病毒。' 'Yellow'
    Say '    半路卡住、装完找不到 astrbot.exe、QQ 一直闪退，都先怀疑它。' 'Yellow'
    Say '    真遇上了：把这个目录整块加进白名单（或临时关实时防护），再重跑——' 'Yellow'
    Say ('      ' + $script:Root) 'White'
    Say '    已经装好的东西不会白装，重跑是接着装。' 'DarkGray'
}

# ── 基础工具 ───────────────────────────────────────────────────────────────
function Backup-File([string]$Path) {
    if (Test-Path $Path) {
        $bak = '{0}.bak-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $Path $bak -Force
        Info ('已备份原配置：' + (Split-Path $bak -Leaf))
    }
}

function Read-Json([string]$Path) {
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $raw = $raw -replace '^\uFEFF', ''
    try { return ($raw | ConvertFrom-Json) }
    catch { Fail ('配置文件不是合法 JSON：' + $Path) ("这个文件可能被手动改坏了。先还原成同目录的 .bak-时间戳 备份，再重跑。`n出错位置：" + $_.Exception.Message) }
}

function Write-Json([string]$Path, $Object) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 40
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json + "`n", $utf8)
}

# 给从 JSON 读回来的对象设字段。PS 5.1 里对 PSCustomObject 直接 `$o.新字段 = x`
# 会抛 "The property 'x' cannot be found on this object"——老配置缺字段时必崩。
# 统一走 Add-Member -Force，缺了就补、有就覆盖。
function Set-Prop($Object, [string]$Name, $Value) {
    if ($null -eq $Object) { return }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Test-PortListen([int]$Port) {
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSec, [string]$ProgressText = '') {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($script:InterruptRequested) { throw '用户已请求中断' }
        if (& $Condition) {
            if ($ProgressText -ne '' -and -not $Quiet) { Write-Host '' }
            return $true
        }
        if ($ProgressText -ne '' -and -not $Quiet) {
            Write-Host ("`r    等待 " + $ProgressText + " ... 还剩 " + [int]($deadline - (Get-Date)).TotalSeconds + " 秒") -NoNewline -ForegroundColor DarkGray
        }
        Start-Sleep -Milliseconds 1000
    }
    if ($ProgressText -ne '' -and -not $Quiet) { Write-Host '' }
    return $false
}

# ── AstrBot：识别 / 安装 / 配置 / 启动 ─────────────────────────────────────
function Get-LauncherInstances {
    $instances = Join-Path $env:USERPROFILE '.astrbot_launcher\instances'
    if (-not (Test-Path $instances)) { return @() }
    return @(Get-ChildItem $instances -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'core\main.py') } |
        Sort-Object LastWriteTime -Descending)
}

function Get-AstrBotCli {
    # 自家装的优先：ds-as-nap\astrbot\.venv\Scripts\astrbot.exe
    $own = Join-Path $script:AbDir '.venv\Scripts\astrbot.exe'
    if (Test-Path $own) { return $own }

    $cmd = Get-Command 'astrbot' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    $cands = @(
        (Join-Path $env:USERPROFILE '.local\bin\astrbot.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\astrbot'),
        (Join-Path $env:APPDATA 'uv\tools\astrbot\Scripts\astrbot.exe'),
        (Join-Path $env:APPDATA 'uv\tools\astrbot\bin\astrbot.exe')
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

# ── uv / Python：全程绕开 GitHub ───────────────────────────────────────────
# 背景：官方 install.ps1 先从 USTC 镜像取 uv（对大文件回 403），再退回 GitHub；
# GitHub 不通的机器就死在这一步。而 astrbot 和 uv 本身都在 PyPI 上，
# Python 3.12 又有 npmmirror 的官方安装包——这三条都不必经过 GitHub。

function Get-TextWithTimeout([string]$Url, [int]$TimeoutSec = 20) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'DSH-Deploy/1.0'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $true
    try {
        $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    } catch { }
    if ($script:ProxyUrl) { Set-RequestProxy $req $Url }
    try {
        $resp = $req.GetResponse()
    } catch {
        if (-not $script:ProxyUrl) { throw }
        Warn ('取文本失败，改直连再试：' + $_.Exception.Message)
        $script:ProxyUrl = $null
        $req.Proxy = $null
        $resp = $req.GetResponse()
    }
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Close() }
    } finally { $resp.Close() }
}

function Add-PathEntry([string]$Dir) {
    if (-not $Dir) { return }
    if (($env:PATH -split ';') -notcontains $Dir) { $env:PATH = $Dir + ';' + $env:PATH }
}

function Get-UvOnPath {
    # 自家目录优先，其次才找系统里已有的
    foreach ($p in @(
            (Join-Path $script:UvDir 'uv.exe'),
            (Join-Path $env:USERPROFILE '.local\bin\uv.exe'),
            (Join-Path $env:LOCALAPPDATA 'uv\uv.exe')
        )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $c = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }
    return $null
}

# 从 PyPI 镜像的 simple 页面里挑出最新一个 win_amd64 wheel（自带 sha256）
function Get-UvWheelFromIndex([string]$IndexUrl) {
    $html = Get-TextWithTimeout -Url $IndexUrl -TimeoutSec 20
    if (-not $html) { return $null }
    $ms = [regex]::Matches($html, 'href="([^"#]+uv-[0-9][^"#]*-py3-none-win_amd64\.whl)(?:#sha256=([0-9a-fA-F]{64}))?"')
    if ($ms.Count -eq 0) { return $null }
    $m = $ms[$ms.Count - 1]
    $abs = ([Uri]::new([Uri]$IndexUrl, $m.Groups[1].Value)).AbsoluteUri
    return [pscustomobject]@{ Url = $abs; Sha256 = $m.Groups[2].Value }
}

function Ensure-Uv {
    $existing = Get-UvOnPath
    if ($existing) {
        Add-PathEntry (Split-Path $existing -Parent)
        Ok ('uv 已在：' + $existing)
        return $existing
    }

    Info '没有 uv：从 PyPI 镜像取 wheel（约 20 MB，不走 GitHub）'
    $binDir = $script:UvDir
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

    $indexes = @(
        [pscustomobject]@{ Name = '清华'; Url = 'https://pypi.tuna.tsinghua.edu.cn/simple/uv/' },
        [pscustomobject]@{ Name = '阿里'; Url = 'https://mirrors.aliyun.com/pypi/simple/uv/' },
        [pscustomobject]@{ Name = 'cernet'; Url = 'https://mirrors.cernet.edu.cn/pypi/web/simple/uv/' }
    )
    foreach ($idx in $indexes) {
        try {
            Info ('查索引：' + $idx.Name)
            $info = Get-UvWheelFromIndex -IndexUrl $idx.Url
            if (-not $info) { Warn ('这个索引里没有 win_amd64 的 wheel：' + $idx.Name); continue }

            $whl = Join-Path $script:Root 'uv-wheel.zip'
            $null = Get-FileWithProgress -Url $info.Url -OutFile $whl -Label ('uv (' + $idx.Name + ')') -Sha256 $info.Sha256 -MaxRetry 2
            $tmp = Join-Path $script:Root 'uv-extract'
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
            Expand-Archive -Path $whl -DestinationPath $tmp -Force
            $exe = Get-ChildItem $tmp -Recurse -Filter 'uv.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exe) { Warn 'wheel 解包后没有 uv.exe'; continue }

            Copy-Item (Join-Path $exe.DirectoryName 'uv*.exe') -Destination $binDir -Force
            Remove-Item $whl -Force -ErrorAction SilentlyContinue
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            Add-PathEntry $binDir

            $uvPath = Join-Path $binDir 'uv.exe'
            if (-not (Test-Path $uvPath)) { Warn '复制后找不到 uv.exe'; continue }
            Ok ('uv 就位：' + (& $uvPath --version))
            return $uvPath
        } catch {
            if ($script:InterruptRequested) { throw }
            Warn ('这个镜像不行（' + $idx.Name + '）：' + $_.Exception.Message)
        }
    }
    return $null
}

function Get-Python312Path {
    # 自家装的优先
    $own = Join-Path $script:PyDir 'python.exe'
    if (Test-Path $own) { return $own }

    # py launcher 里的记录可能指向已删除的目录，必须验证存在
    try {
        $lines = @(& py -0p 2>$null)
        foreach ($l in $lines) {
            $s = [string]$l
            if ($s -match '3\.12' -and $s -match '([A-Za-z]:\\[^\r\n]*?python\.exe)') {
                $cand = $matches[1]
                if (Test-Path $cand) { return $cand }
            }
        }
    } catch { }
    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
            'C:\Program Files\Python312\python.exe',
            (Join-Path $env:ProgramFiles 'Python312\python.exe')
        )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-Python312 {
    # 不用官方安装器：它会在注册表里留 "已安装" 记录，某些机器上再跑会直接
    # 认为装过了、什么都不做（WixBundleInstalled=1，退出码还是 0）。
    # 改用可嵌入版 zip —— 纯解包，不写注册表，装在哪就是哪。
    Info '没有 Python 3.12：下载可嵌入版（约 11 MB，纯解包，不写注册表）'

    $zip = Join-Path $script:Root 'python-embed.zip'
    if (-not (Test-Path $zip)) {
        $mirrors = @(
            [pscustomobject]@{ Name = 'npmmirror'; Url = 'https://registry.npmmirror.com/-/binary/python/3.12.10/python-3.12.10-embed-amd64.zip' },
            [pscustomobject]@{ Name = 'python.org'; Url = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' }
        )
        if (-not (Get-FileFromMirrors -Mirrors $mirrors -OutFile $zip)) { return $null }
    } else {
        Info ('复用安装包：' + $zip)
    }

    if (Test-Path $script:PyDir) { Remove-Item $script:PyDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $script:PyDir -Force | Out-Null
    if (-not (Expand-ZipSafe $zip $script:PyDir)) {
        return $null
    }

    # 可嵌入版默认不加载 site-packages，放开 import site 才能装第三方包
    $pth = Get-ChildItem $script:PyDir -Filter '*._pth' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pth) {
        try {
            $lines = Get-Content $pth.FullName
            $fixed = $lines -replace '^#\s*import site\s*$', 'import site'
            Set-Content -Path $pth.FullName -Value $fixed -Encoding ASCII
        } catch {
            Warn ('改 _pth 失败：' + $_.Exception.Message)
        }
    }

    $py = Join-Path $script:PyDir 'python.exe'
    if (-not (Test-Path $py)) { Warn '解包后没有 python.exe'; return $null }
    try {
        $ver = (& $py --version 2>&1) -join ' '
        Ok ('Python 3.12 就位：' + $ver)
    } catch { }
    return $py
}

# 镜像测速：同一个包，不同镜像能差好几倍。先量一下再决定用哪个。
function Get-IndexSpeed([string]$IndexUrl) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Get-TextWithTimeout -Url ($IndexUrl.TrimEnd('/') + '/astrbot/') -TimeoutSec 8
        $sw.Stop()
        return [int]$sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        return 99999
    }
}

function Sort-IndexesBySpeed([string[]]$Indexes) {
    if ($Indexes.Count -le 1) { return $Indexes }
    $scored = @()
    $i = 0
    foreach ($idx in $Indexes) {
        $i++
        if (-not $Quiet) { Info ('测速（' + $i + '/' + $Indexes.Count + '）：' + $idx) }
        $ms = Get-IndexSpeed $idx
        $scored += [pscustomobject]@{ Url = $idx; Ms = $ms }
    }

    $sorted = @($scored | Sort-Object Ms | ForEach-Object { $_.Url })
    $best = $scored | Sort-Object Ms | Select-Object -First 1
    if ($best -and $best.Ms -lt 9000) { Info ('最快的镜像：' + $best.Url + '（' + $best.Ms + ' ms）') }
    return $sorted
}

# 路线 A：在 ds-as-nap\astrbot 建独立 venv，走 PyPI 镜像装
# 路线 A：在 ds-as-nap\astrbot 里建独立 venv，把 astrbot 装进去（全部走 PyPI 镜像）
function Install-AstrBotViaUv {
    $uv = Ensure-Uv
    if (-not $uv) { Warn '拿不到 uv'; return $false }

    $py = Get-Python312Path
    if (-not $py) { $py = Install-Python312 }
    if (-not $py) { Warn '拿不到 Python 3.12'; return $false }
    Ok ('Python 3.12：' + $py)

    $venvDir = Join-Path $script:AbDir '.venv'
    $venvPy = Join-Path $venvDir 'Scripts\python.exe'

    if (-not (Test-Path $venvPy)) {
        Info ('建独立环境：' + $venvDir)
        Info '  venv 要在一分钟内写出上千个文件，杀软边写边扫会拖慢，个别还会直接把 python.exe 挡住'
        $log = Join-Path $script:LogDir ('venv-{0}.log' -f (Get-Date -Format 'HHmmss'))
        $p = Start-Process -FilePath $uv -PassThru -NoNewWindow `
            -ArgumentList @('venv', ('"' + $venvDir + '"'), '--python', ('"' + $py + '"')) `
            -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
        $code = Wait-ProcessWithProgress -Process $p -Label '建 venv' -TimeoutSec 300 -LogPath $log
        if ($code -ne 0 -and -not (Test-Path $venvPy)) {
            $tail = ''
            $t = @(Read-LogTail -Path ($log + '.err') -Lines 8)
            if ($t.Count -gt 0) { $tail = ($t -join "`n") }
            Warn ('建 venv 失败（退出码 ' + $code + '）')
            if ($tail) { Warn $tail }
            Warn '最常见的原因不是 uv 有问题，是杀软拦了写文件、或者这个目录没权限。'
            Warn '把下面这个目录加进白名单（或临时关掉实时防护），再重跑本脚本：'
            Warn ('  ' + $script:AsRoot)
            return $false
        }
    } else {
        Info ('复用已有环境：' + $venvDir)
    }
    if (-not (Test-Path $venvPy)) { Warn 'venv 里没有 python.exe'; return $false }

    $indexes = @(
        'https://pypi.tuna.tsinghua.edu.cn/simple',
        'https://mirrors.aliyun.com/pypi/simple',
        'https://mirrors.ustc.edu.cn/pypi/simple',
        'https://mirror.nju.edu.cn/pypi/web/simple',
        'https://mirrors.cernet.edu.cn/pypi/web/simple'
    )
    # 先量一下哪个镜像快：装 300 多个包，源慢一倍就是十几分钟
    $indexes = @(Sort-IndexesBySpeed $indexes)
    foreach ($idx in $indexes) {
        Info ('装 astrbot 到这个环境  ←  ' + $idx)
        Info '  约 250 MB、150 多个包；进度看上面的条，或每 20 秒滚的那行'
        $log = Join-Path $script:LogDir ('astrbot-pip-{0}.log' -f (Get-Date -Format 'HHmmss'))
        $p = Start-Process -FilePath $uv -PassThru -NoNewWindow `
            -ArgumentList @('pip', 'install', '--python', ('"' + $venvPy + '"'), 'astrbot', '--default-index', $idx) `
            -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
        # StallSec：连着 4 分钟日志一个字都不长，就是这条连接死了（镜像 WAF 限流、
        # 代理黑洞都长这样），直接杀掉换下一条索引，别干等到 30 分钟总超时
        $code = Wait-ProcessWithProgress -Process $p -Label '安装 astrbot' -TimeoutSec 1800 -LogPath $log -StallSec 240

        $cli = Join-Path $venvDir 'Scripts\astrbot.exe'
        if ($code -eq 0 -and (Test-Path $cli)) {
            Ok ('astrbot 装好了：' + $cli)
            return $true
        }
        if ($code -eq -3) { Warn ('这个镜像 4 分钟没有新动静，换下一条：' + $idx); continue }
        if ($code -eq -2) { Warn '装 astrbot 超时，换下一条索引'; continue }
        # -1 = PS 拿不到退出码：以“可执行文件在不在”为准
        if ($code -lt 0 -and (Test-Path $cli)) {
            Ok 'astrbot 装好了（退出码读不到，但文件已就位）'
            return $true
        }
        $tail = ''
        $t = @(Read-LogTail -Path ($log + '.err') -Lines 6)
        if ($t.Count -gt 0) { $tail = ($t -join "`n") }
        Warn ('这个索引装不下来（退出码 ' + $code + '）：' + $tail)
        if ($tail -match 'Permission denied|Access is denied|being used by another process|拒绝访问') {
            Warn '看着像被锁了文件：大概率是杀软正在扫/隔离，把上面那个目录加进白名单再重跑'
        }
    }
    return $false
}

# 路线 B：官方 install.ps1（能连 GitHub 的机器上更快，也更“原厂”）
function Install-AstrBotOfficial {
    $ps1 = Join-Path $script:Root 'install.astrbot.ps1'
    if (-not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }

    if (-not (Test-Path $ps1)) {
        Info ('取安装脚本：' + $script:InstallUrl)
        try {
            $null = Get-FileWithProgress -Url $script:InstallUrl -OutFile $ps1 -Label 'install.ps1' -MaxRetry 3
        } catch {
            Fail '下载 AstrBot 安装脚本失败' ("docs.astrbot.app 取不到。`n1) 回头看第一步的联网预检：文档站是不是标了不通`n2) 设好系统代理再重跑（脚本会自动识别）`n3) 或者用浏览器打开 " + $script:InstallUrl + "，另存为：" + $ps1 + "`n详细：" + $_.Exception.Message)
        }
        Ok ('安装脚本已就位（{0:N0} KB）' -f ((Get-Item $ps1).Length / 1KB))
    } else {
        Info ('复用已下载的安装脚本：' + $ps1)
    }

    Info '官方脚本自己画进度条，那些进度不会写进日志——所以这条路上可能很久看不到字，别以为死了'
    Info '（真嫌慢就按 Ctrl+C 连按两次停掉，删掉 ds-as-nap\astrbot\.venv 后重跑，会换条路重试）'
    $log = Join-Path $script:LogDir ('astrbot-install-{0}.log' -f (Get-Date -Format 'HHmmss'))
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ps1 + '"'), '-Language', 'zh-CN', '-DownloadSource', $DownloadSource, '-NonInteractive') `
        -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru -NoNewWindow

    $code = Wait-ProcessWithProgress -Process $proc -Label '安装 AstrBot（官方脚本）' -TimeoutSec 1500 -LogPath $log
    if ($code -eq -2) {
        Fail 'AstrBot 安装超过 15 分钟没动静' ("日志：" + $log + "`n先跑一次 -Action Check 看装到哪一步了。")
    }
    if ($code -lt 0 -and -not (Get-AstrBotCli)) {
        # 退出码读不到，且也没装出来：按失败处理，但把话说明白
        $tail = ''
        if (Test-Path $log) { $tail = ((Read-LogTail -Path $log -Lines 12) -join "`n") }
        Fail 'AstrBot 安装脚本跑完了，但既读不到退出码、也没找到 astrbot 命令' ("日志末尾：`n" + $tail)
    }
    if ($code -gt 0) {
        $tail = ''
        if (Test-Path $log) { $tail = ((Read-LogTail -Path $log -Lines 12) -join "`n") }
        Fail ('AstrBot 安装脚本返回错误码 ' + $code) ("1) 看下面日志末尾`n2) 换网络重试（手机热点最省事）`n3) 别加 -DownloadSource official：国内那条路更差`n`n日志末尾：`n" + $tail)
    }
}

function Install-AstrBot {
    Step '2.1' '部署 AstrBot'

    Say ''
    Say '   这一步要下 AstrBot 本体 + 150 多个依赖，约 250 MB。' 'Yellow'
    Say '   网快 3~5 分钟，网慢 15~20 分钟——慢是正常的，先别怀疑卡死。' 'Yellow'
    Say '   进度看两处：窗口顶上那行会一直刷，每 20 秒还会滚一行带时间戳的记录。' 'Yellow'
    Say '   去泡杯茶可以，但别关这个窗口。' 'Yellow'
    Say ''

    Warn '安装期间窗口关闭按钮会失效（防误关）；真要中止，连按两次 Ctrl+C'
    Set-CloseButton $false
    Write-RunMarker '安装 AstrBot'
    try {
        Info '路线 A：PyPI 镜像直装（uv wheel + Python 3.12 + astrbot，全程不碰 GitHub）'
        $okA = $false
        try { $okA = Install-AstrBotViaUv } catch { Warn ('路线 A 出错：' + $_.Exception.Message) }

        if ($okA) {
            $cli = Get-AstrBotCli
            if ($cli) { Ok ('AstrBot 装好了：' + $cli); return }
            Warn '装完了但没找到 astrbot 命令，换路线 B'
        } else {
            Warn '路线 A 没成，改走官方 install.ps1'
        }

        Install-AstrBotOfficial

        if (-not (Get-AstrBotCli)) {
            Fail '安装脚本说成功了，但找不到 astrbot 命令' @"
PATH 可能没刷新。按顺序试：
  1) 关掉窗口重开一个 PowerShell，再跑本脚本（会自动认出）
  2) where.exe astrbot
  3) 看日志目录：$script:LogDir
"@
        }
        Ok 'AstrBot 装好了'
    } finally {
        Set-CloseButton $true
    }
}

function Resolve-AstrBot {
    Step 2 '定位 AstrBot'

    if ($Mode -eq 'launcher') {
        if ($AstrBotDir) { $inst = $AstrBotDir }
        else { $found = @(Get-LauncherInstances); if ($found.Count -gt 0) { $inst = $found[0].FullName } }
        if (-not $inst -or -not (Test-Path (Join-Path $inst 'core\main.py'))) {
            Fail '没找到启动器安装的 AstrBot' '用 -AstrBotDir 指向实例目录，或者把 -Mode 改成 auto / cli 让脚本走官方脚本部署。'
        }
        Ok ('使用启动器实例：' + $inst)
        return [pscustomobject]@{ Kind = 'launcher'; Root = $inst; Config = (Join-Path $inst 'core\data\cmd_config.json') }
    }

    if ($Mode -eq 'auto') {
        $found = @(Get-LauncherInstances)
        if ($found.Count -gt 0) {
            Ok ('发现启动器实例（-Mode auto 优先用它）：' + $found[0].Name)
            Info '想改走 CLI 部署：加 -Mode cli'
            return [pscustomobject]@{ Kind = 'launcher'; Root = $found[0].FullName; Config = (Join-Path $found[0].FullName 'core\data\cmd_config.json') }
        }
    }

    if (-not $AstrBotDir -and -not (Get-AstrBotCli)) {
        Warn '没找到 astrbot 命令，先装'
        Install-AstrBot
    }

    $cli = Get-AstrBotCli
    if (-not $cli) {
        Fail '装完了还是找不到 astrbot 命令' @"
通常是 PATH 没刷新。按顺序试：

  1) 关掉这个窗口，重新开一个 PowerShell 再跑（PATH 是登录时读的）
  2) 或者手动执行：where.exe astrbot
  3) 还不行就看日志：<脚本目录>\ds-as-nap\logs\astrbot-install-*.log
"@
    }
    Ok ('astrbot：' + $cli)

    $work = $WorkDir
    if (-not $work) { $work = $script:AbDir }
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    Ok ('工作目录：' + $work)
    return [pscustomobject]@{ Kind = 'cli'; Root = $work; Config = (Join-Path $work 'data\cmd_config.json'); Cli = $cli }
}

function Initialize-AstrBotWorkdir($Target) {
    if ($Target.Kind -ne 'cli') { return }
    Step '2.2' '初始化 AstrBot 工作目录（astrbot init）'

    if (Test-Path $Target.Config) { Ok '已有配置，跳过 init'; return }

    $cli = $Target.Cli
    $empty = Join-Path $script:Root 'empty.stdin'
    Set-Content -Path $empty -Value '' -Encoding ASCII
    $out = Join-Path $script:LogDir 'astrbot-init.log'
    try {
        $p = Start-Process -FilePath $cli -ArgumentList @('init') -WorkingDirectory $Target.Root `
            -RedirectStandardInput $empty -RedirectStandardOutput $out -RedirectStandardError ($out + '.err') -PassThru -NoNewWindow
        $null = $p.WaitForExit(180000)
    } catch {
        Warn ('astrbot init 没跑起来：' + $_.Exception.Message)
    }

    if (Test-Path $Target.Config) { Ok '工作目录初始化完成'; return }
    Warn 'init 之后还没看到配置文件：先启动一次 AstrBot，它会自己生成'
}

function Get-AstrBotProcess {
    # AstrBot 有两种跑法，都得认：
    #   1) 源码跑：python.exe ...\core\main.py
    #   2) 装出来的：python.exe "...\Scripts\astrbot.exe" run  ← 我们现在走的是这条
    # 只认第一种的话，自检会一直报"AstrBot 进程不在"，可 6199 明明是它在听。
    # （python.exe 被硬塞进命令行，是因为 venv 里的 astrbot.exe 只是个启动壳，
    #   真干活的进程名还是 python.exe。）
    $list = @()
    $list += @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -match 'core\\main\.py' -or $_.CommandLine -match 'astrbot\.exe') })
    $list += @(Get-CimInstance Win32_Process -Filter "Name='astrbot.exe'" -ErrorAction SilentlyContinue)
    return $list
}

function Stop-AstrBot {
    $procs = Get-AstrBotProcess
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    return ($procs.Count -gt 0)
}

function Start-AstrBot($Target) {
    $logOut = Join-Path $script:LogDir 'astrbot.out.log'
    $logErr = Join-Path $script:LogDir 'astrbot.err.log'

    if ($Target.Kind -eq 'cli') {
        Info '启动 astrbot run（后台，日志 logs\astrbot.out.log）'
        Start-Process -FilePath $Target.Cli -ArgumentList @('run') -WorkingDirectory $Target.Root `
            -RedirectStandardOutput $logOut -RedirectStandardError $logErr -WindowStyle Hidden
        return
    }

    $py = Join-Path $Target.Root 'venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { Fail ('这个实例里没有 Python 环境：' + $Target.Root) '启动器装的实例缺运行环境，用启动器重装，或改用 -Mode cli。' }
    Info '启动 AstrBot（后台，日志 logs\astrbot.out.log）'
    Start-Process -FilePath $py -ArgumentList ('"' + (Join-Path $Target.Root 'core\main.py') + '"') -WorkingDirectory (Join-Path $Target.Root 'core') `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr -WindowStyle Hidden
}

# ── 写 AstrBot 配置 ────────────────────────────────────────────────────────
function Set-AstrBotConfig($Target, [string]$QQNumber, [string]$Key, [switch]$GroupMode, [string]$Wake = "小五", [string]$Gid = "") {
    Step 4 '对齐 AstrBot 的 OneBot 服务端信息'

    if (-not (Test-Path $Target.Config)) {
        # 没有配置时，先用内置模板初始化：模板里是作者调好的模型/人格/平台结构，
        # 装完直接就是"能聊"的状态，不用客户自己从头配。
        $tpl = Join-Path $PSScriptRoot 'templates\cmd_config.template.json'
        if (Test-Path $tpl) {
            $dstDir = Split-Path $Target.Config -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item $tpl $Target.Config -Force
            Info '用内置模板初始化配置（模型、人格都按调好的来）'
        } else {
            Fail ('找不到 AstrBot 配置：' + $Target.Config) '先把 AstrBot 启动一次，让它生成 data\cmd_config.json，再重跑本脚本。'
        }
    }
    Backup-File $Target.Config
    $cfg = Read-Json $Target.Config
    $changed = $false

    if (-not $cfg.platform) { $cfg | Add-Member -NotePropertyName platform -NotePropertyValue @() -Force }
    $platforms = @($cfg.platform)
    $plat = $platforms | Where-Object { $_.type -eq 'aiocqhttp' } | Select-Object -First 1

    if (-not $plat) {
        $plat = [pscustomobject]@{
            id = 'deploy'; type = 'aiocqhttp'; enable = $true
            ws_reverse_host = '0.0.0.0'; ws_reverse_port = $OneBotPort
            ws_reverse_token = (-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }))
        }
        $platforms += $plat
        $changed = $true
        Ok ('没有 OneBot 平台，已新建：端口 ' + $OneBotPort)
    } else {
        if ($plat.enable -ne $true) { Set-Prop $plat 'enable' $true; $changed = $true }
        if (-not $plat.ws_reverse_port) { Set-Prop $plat 'ws_reverse_port' $OneBotPort; $changed = $true }
        if (-not $plat.ws_reverse_token) {
            Set-Prop $plat 'ws_reverse_token' (-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }))
            $changed = $true
        }
    }
    Set-Prop $cfg 'platform' $platforms

    $obPort = [int]$plat.ws_reverse_port
    $obToken = [string]$plat.ws_reverse_token
    Ok ('服务端信息：端口 ' + $obPort + '，token ' + $obToken.Substring(0, [Math]::Min(6, $obToken.Length)) + '…（前六位）')

    if ($Key -ne '') {
        if (-not $cfg.provider_sources) { $cfg | Add-Member -NotePropertyName provider_sources -NotePropertyValue @() -Force }
        $src = @($cfg.provider_sources) | Where-Object { $_.provider -eq 'deepseek' } | Select-Object -First 1
        if (-not $src) {
            $src = [pscustomobject]@{
                provider = 'deepseek'; type = 'openai_chat_completion'; provider_type = 'chat_completion'
                key = @($Key); api_base = 'https://api.deepseek.com/v1'; timeout = 120; proxy = ''
                custom_headers = @{}; id = 'deepseek'; enable = $true
            }
            $cfg.provider_sources = @($cfg.provider_sources) + $src
            $changed = $true
        } else {
            Set-Prop $src 'key' @($Key)
            Set-Prop $src 'enable' $true
            $changed = $true
        }
        if (-not $cfg.provider) { $cfg | Add-Member -NotePropertyName provider -NotePropertyValue @() -Force }
        $prov = @($cfg.provider) | Where-Object { $_.id -eq ('deepseek/' + $Model) } | Select-Object -First 1
        if (-not $prov) {
            $prov = [pscustomobject]@{
                id = 'deepseek/' + $Model; enable = $true; provider_source_id = 'deepseek'; model = $Model
                modalities = @('text', 'image', 'tool_use'); custom_extra_body = @{}; max_context_tokens = 1000000
            }
            $cfg.provider = @($cfg.provider) + $prov
            $changed = $true
        }
        Ok ('模型 deepseek/' + $Model + ' 已配置')
    } else {
        Info '没给 API Key：模型不动，客户自己在 WebUI 里填'
    }

    if (-not $cfg.admins_id) { $cfg | Add-Member -NotePropertyName admins_id -NotePropertyValue @() -Force }
    $admins = @(@($cfg.admins_id) | Where-Object { $_ -match '^\d{5,12}$' -or $_ -eq 'astrbot' })
    if ($admins -notcontains $QQNumber) { $admins += $QQNumber; $cfg.admins_id = $admins; $changed = $true; Ok ('管理员已加入 ' + $QQNumber) }

    if ($GroupMode) {
        if (-not $cfg.platform_settings) { $cfg | Add-Member -NotePropertyName platform_settings -NotePropertyValue ([pscustomobject]@{}) -Force }
        $ps = $cfg.platform_settings
        Set-Prop $ps 'enable_id_white_list' $true
        $wl = @(@($ps.id_whitelist) | Where-Object { $_ -ne $null -and "$_" -ne '' })
        if ($Gid -ne '' -and ($wl -notcontains $Gid)) { $wl += $Gid }
        if ($wl.Count -gt 0) { Set-Prop $ps 'id_whitelist' $wl }
        if (-not $ps.rate_limit) { Set-Prop $ps 'rate_limit' ([pscustomobject]@{}) }
        Set-Prop $ps.rate_limit 'time' 60
        Set-Prop $ps.rate_limit 'count' 12
        Set-Prop $ps.rate_limit 'strategy' 'stall'
        Set-Prop $ps 'friend_message_needs_wake_prefix' $false
        Set-Prop $ps 'ignore_bot_self_message' $true
        Set-Prop $cfg 'wake_prefix' @($Wake)
        $changed = $true
        Ok ('群聊预设：唤醒词「' + $Wake + '」')
        if ($Gid -ne '') { Ok ('群白名单：' + $Gid) } else { Info '没给群号：白名单留空，等你在群里用 /sid 拿到群号后再加' }
        Ok '限流：每人每分钟 12 条（超出排队不回）'
        Ok 'Agent 执行权限保持关闭（群聊不需要，也不该给）'
    }

    # 面板密码：直接给客户设一个已知的，两个面板共用
    $panelPw = New-PanelPassword
    if (-not $cfg.dashboard) { $cfg | Add-Member -NotePropertyName dashboard -NotePropertyValue ([pscustomobject]@{}) -Force }
    Set-Prop $cfg.dashboard 'enable' $true
    Set-Prop $cfg.dashboard 'username' 'astrbot'
    Set-Prop $cfg.dashboard 'password' (Get-Md5Hex $panelPw)
    Set-Prop $cfg.dashboard 'pbkdf2_password' (Get-Pbkdf2Hash $panelPw)
    Set-Prop $cfg.dashboard 'password_storage_upgraded' $true
    Set-Prop $cfg.dashboard 'password_change_required' $false
    $script:PanelPassword = $panelPw
    Ok ('面板密码已设置：' + $panelPw)

    Write-Json $Target.Config $cfg
    return [pscustomobject]@{ Port = $obPort; Token = $obToken; Changed = $changed; PanelPassword = $panelPw }
}

# ── NapCat：识别 / 配置 / 启动 ─────────────────────────────────────────────
function Get-NapCatConfigDirs([string]$Root) {
    # 返回候选 config 目录（可能还不存在——首次启动前 NapCat 没建，我们会自己建）
    $found = @()

    $direct = Join-Path $Root 'config'
    if (Test-Path $direct) { $found += (Resolve-Path $direct).Path }

    $versions = Join-Path $Root 'versions'
    if (Test-Path $versions) {
        Get-ChildItem $versions -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $nap = Join-Path $_.FullName 'resources\app\napcat'
            if (Test-Path $nap) { $found += (Join-Path $nap 'config') }
        }
    }

    if ($found.Count -eq 0) {
        Get-ChildItem $Root -Recurse -Depth 5 -Directory -Filter 'napcat' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch 'bootmain' } |
            ForEach-Object { $found += (Join-Path $_.FullName 'config') }
    }
    return @($found | Select-Object -Unique)
}

function Test-NapCatRoot([string]$Root) {
    if (-not (Test-Path (Join-Path $Root 'NapCatWinBootMain.exe'))) { return $false }
    if ((Split-Path $Root -Leaf) -match 'bootmain') { return $false }
    if ((Split-Path $Root -Leaf) -match '^NapCat\.[\d.]+\.Shell$') { return $true }   # 一体包
    return ((Get-NapCatConfigDirs $Root).Count -gt 0)
}

function Test-NapCatSelfContained([string]$Root) {
    # 自带 QQ 的一体包：根目录里有 versions\<qq版本>-<build>\resources\app\napcat
    $versions = Join-Path $Root 'versions'
    if (-not (Test-Path $versions)) { return $false }
    foreach ($d in (Get-ChildItem $versions -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $d.FullName 'resources\app\napcat')) { return $true }
    }
    return $false
}

# 这份 NapCat 能不能配这台机器的 QQ：比 qqnt.json 的 buildVersion 和 QQ 的 build 号。
# 拿不准的一律放行（没有清单、没有 QQ、解析不出来），只在"明确对不上"时返回 false。
function Test-NapCatQqBuild([string]$NapCatPath) {
    # 一体包自带一整套 QQ，版本天生自洽，不该跟机器上那个比
    if (Test-NapCatSelfContained $NapCatPath) { return $true }
    $qqnt = Join-Path $NapCatPath 'qqnt.json'
    if (-not (Test-Path $qqnt)) { return $true }
    $want = ''
    try { $want = [string](Get-Content $qqnt -Raw -Encoding UTF8 | ConvertFrom-Json).buildVersion } catch { }
    if (-not $want) { return $true }
    $qq = Get-QqClientInfo
    if (-not $qq) { return $true }
    $have = ''
    if ($qq.Version -match '-(\d+)$') { $have = $matches[1] }
    if (-not $have) { return $true }
    return ($want -eq $have)
}

function Install-NapCatOneKey {
    Step '3.1' '安装 NapCat 一体包（自带 QQ，不用客户预装）'

    $base = $script:NcDir
    # 上一轮要是装过 Shell 包，这里会留一堆残留；和一体包混在一起，后面找目录会认岔
    if (Test-Path (Join-Path $base 'NapCatWinBootMain.exe')) {
        Info '清掉上一次 Shell 包的残留'
        Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }

    $zip = Join-Path $base 'NapCat.Shell.Windows.OneKey.zip'
    if (-not (Test-Path $zip)) {
        $onekeyPath = 'NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.Windows.OneKey.zip'
        $mirrors = @()
        # 直连能不能用，预检已经告诉过我们了；通的排前面，省时间
        if (-not $script:Net.ContainsKey('github') -or $script:Net['github']) {
            $mirrors += [pscustomobject]@{ Name = 'GitHub 直连'; Url = ('https://github.com/' + $onekeyPath) }
        }
        $mirrors += [pscustomobject]@{ Name = 'gh-proxy'; Url = ('https://gh-proxy.com/https://github.com/' + $onekeyPath) }
        $mirrors += [pscustomobject]@{ Name = 'ghproxy'; Url = ('https://ghproxy.net/https://github.com/' + $onekeyPath) }
        $mirrors += [pscustomobject]@{ Name = 'ghfast'; Url = ('https://ghfast.top/https://github.com/' + $onekeyPath) }
        if (-not $script:Net.ContainsKey('github') -or $script:Net['github']) {
            $mirrors += [pscustomobject]@{ Name = 'GitHub 直连（重试）'; Url = ('https://github.com/' + $onekeyPath) }
        }

        $ok = Get-FileFromMirrors -Mirrors $mirrors -OutFile $zip
        if (-not $ok) {
            Fail 'NapCat 一体包下载失败（所有源都没通）' ("手动下这个文件放到：`n" + $zip + "`n地址：https://github.com/NapNeko/NapCatQQ/releases/latest （找 NapCat.Shell.Windows.OneKey.zip）`n放好后再跑一次本脚本，会跳过下载。")
        }
        if ((Get-Item $zip).Length -lt 100000) { Fail '下载到的文件太小，不像安装包' ('删掉重试：' + $zip) }
    } else {
        Info ('已有安装包，跳过下载：' + $zip)
    }

    if (-not (Expand-ZipSafe $zip $base)) { Fail '一体包解压失败' ('包可能下坏了，删掉重下：' + $zip) }
    $installer = Join-Path $base 'NapCatInstaller.exe'
    if (-not (Test-Path $installer)) { Fail '一体包里没有 NapCatInstaller.exe' ('解压目录：' + $base + '；包可能下坏了，删掉重下。') }

    Info '安装器会自己下 QQ 客户端（约 300 MB）和 NapCat（约 34 MB），5~10 分钟，进度实时刷'
    Warn '安装期间窗口关闭按钮会失效（防误关）；真要中止，连按两次 Ctrl+C'
    $log = Join-Path $script:LogDir ('napcat-onekey-{0}.log' -f (Get-Date -Format 'HHmmss'))
    $empty = Join-Path $script:Root 'empty.stdin'
    Set-Content -Path $empty -Value '' -Encoding ASCII

    Set-CloseButton $false
    Write-RunMarker '安装 NapCat 一体包'
    try {
        $p = Start-Process -FilePath $installer -WorkingDirectory $base `
            -RedirectStandardInput $empty -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru -NoNewWindow

        $code = Wait-ProcessWithProgress -Process $p -Label '安装 NapCat' -TimeoutSec 1800 -LogPath $log
        if ($code -eq -2) {
            Fail 'NapCat 一体包安装超过 30 分钟没动静' ('看日志：' + $log + "`n多半卡在下载 QQ（300 MB）。网络差就手动跑一次安装器，完事再重跑本脚本。")
        }
        if ($code -ne 0) {
            # -1 = 拿不到退出码：下面会去找装好的目录，装出来了就算成功
            if ($code -gt 0) {
                $tail = ''
                if (Test-Path $log) { $tail = ((Read-LogTail -Path $log -Lines 12) -join "`n") }
                Fail ('NapCat 安装器返回错误码 ' + $code) ("日志末尾：`n" + $tail)
            }
        }
    } finally {
        Set-CloseButton $true
    }

    $installed = @(Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^NapCat\.[\d.]+\.Shell$' } |
        Where-Object { Test-Path (Join-Path $_.FullName 'NapCatWinBootMain.exe') } |
        Sort-Object LastWriteTime -Descending)

    if ($installed.Count -eq 0) {
        Fail '安装器跑完了，但没找到装好的目录' ('去 ' + $base + ' 里看看有没有 NapCat.xxxxx.Shell；有就用 -NapCatDir 指过去。日志：' + $log)
    }
    Ok ('装好了：' + $installed[0].FullName)
    return $installed[0].FullName
}

# 官方 Shell 包：只有 NapCat 本体，不带 QQ（34 MB 量级，官方文档的手动装法）。
# 机器上已经有 QQ 时走这条，比一体包少下 300 MB。
function Install-NapCatShell {
    Step '3.1' '安装 NapCat（Shell 包，直接用现成的 QQ）'

    $base = $script:NcDir
    $zip = Join-Path $script:Root 'NapCat.Shell.zip'

    if (-not (Test-Path $zip)) {
        $shellPath = 'NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip'
        $mirrors = @()
        # 直连通不通，预检已经告诉过我们了，通的排前面
        if (-not $script:Net.ContainsKey('github') -or $script:Net['github']) {
            $mirrors += [pscustomobject]@{ Name = 'GitHub 直连'; Url = ('https://github.com/' + $shellPath) }
        }
        $mirrors += [pscustomobject]@{ Name = 'gh-proxy'; Url = ('https://gh-proxy.com/https://github.com/' + $shellPath) }
        $mirrors += [pscustomobject]@{ Name = 'ghproxy'; Url = ('https://ghproxy.net/https://github.com/' + $shellPath) }
        $mirrors += [pscustomobject]@{ Name = 'ghfast'; Url = ('https://ghfast.top/https://github.com/' + $shellPath) }
        if (-not (Get-FileFromMirrors -Mirrors $mirrors -OutFile $zip)) {
            Warn 'NapCat Shell 包没下下来'
            return $null
        }
        if ((Get-Item $zip).Length -lt 100000) {
            Warn '下到的 Shell 包太小，不像安装包'
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            return $null
        }
    } else {
        Info ('复用安装包：' + $zip)
    }

    if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    if (-not (Expand-ZipSafe $zip $base)) {
        return $null
    }

    $boot = Get-ChildItem $base -Recurse -Filter 'NapCatWinBootMain.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $boot) {
        Warn '解压后没找到 NapCatWinBootMain.exe'
        return $null
    }
    $root = Split-Path $boot.FullName -Parent

    # 版本对不上就别硬上。NapCat 的注入是按 QQ 的 build 号做的，差一个 build 都可能起不来——
    # 客户看到的现象就是「NapCat 窗口一闪，扫码框永远不出来」。不匹配就返回 $null，
    # 让调用方退回一体包（自带一套对得上的 QQ）。
    $qqnt = Join-Path $root 'qqnt.json'
    if (Test-Path $qqnt) {
        $want = ''
        try { $want = [string](Get-Content $qqnt -Raw -Encoding UTF8 | ConvertFrom-Json).buildVersion } catch { }
        $qq = Get-QqClientInfo
        $have = ''
        if ($qq -and $qq.Version -match '-(\d+)$') { $have = $matches[1] }
        if ($want -and $have -and $want -ne $have) {
            Warn ('注意：这份 NapCat 标称配 QQ build ' + $want + '，你机器上是 ' + $have)
            Warn '版本差着有概率注入失败，但先试这个（34 MB）——不行再退回一体包（334 MB）'
        }
        if ($want -and $have) { Ok ('版本对得上：QQ build ' + $have) }
    }

    Ok ('NapCat 已就位：' + $root)
    return $root
}

function Find-NapCat {
    param([switch]$ExistingOnly)

    if (-not $ExistingOnly) { Step 3 '定位 NapCat' }

    # 清点时已经找到过，别为了同一件事把桌面和下载目录再扫一遍
    if (-not $NapCatDir -and $script:NapCatCache -and (Test-NapCatRoot $script:NapCatCache)) {
        if (-not $ExistingOnly) { Ok ('使用已定位的 NapCat：' + $script:NapCatCache) }
        return $script:NapCatCache
    }

    if ($NapCatDir) {
        if (Test-NapCatRoot $NapCatDir) { Ok ('使用指定目录：' + $NapCatDir); return $NapCatDir }
        Fail ('指定的目录不像 NapCat 根目录：' + $NapCatDir) '要指向含 NapCatWinBootMain.exe 的那层（一体包是 NapCat.xxxxx.Shell），不是 bootmain。'
    }

    $onekey = $script:NcDir
    if (Test-Path $onekey) {
        # Shell 包装出来的：BootMain 直接在这一层，没有子目录
        if (Test-Path (Join-Path $onekey 'NapCatWinBootMain.exe')) {
            if (Test-NapCatQqBuild $onekey) {
                if (-not $ExistingOnly) { Ok ('使用已装好的 NapCat（Shell 包）：' + $onekey) }
                return $onekey
            }
            if (-not $ExistingOnly) {
                Warn ('已装的那份 NapCat 和你的 QQ 版本对不上：' + $onekey)
                Warn '不重装就永远注入不进去，下面换一条路'
            }
        }
        $ready = @(Get-ChildItem $onekey -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^NapCat\.[\d.]+\.Shell$' } |
            Where-Object { Test-Path (Join-Path $_.FullName 'NapCatWinBootMain.exe') } |
            Sort-Object LastWriteTime -Descending)
        if ($ready.Count -gt 0) {
            if (-not $ExistingOnly) { Ok ('使用已装好的一体包：' + $ready[0].FullName) }
            return $ready[0].FullName
        }
    }

    # 用户机器上已有的 NapCat（桌面/下载目录），能直接用就用
    $searchRoots = @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", $script:Root, "$env:ProgramFiles", "$env:LOCALAPPDATA")
    $candidates = @()
    $ri = 0
    foreach ($r in $searchRoots) {
        $ri++
        if (-not (Test-Path $r)) { continue }
        # 扫目录可能要几秒，逐行说一句，别让人以为卡死了
        if (-not $Quiet) { Write-Host ('      找（' + $ri + '/' + $searchRoots.Count + '）：' + $r) -ForegroundColor DarkGray }
        foreach ($h in (Get-ChildItem $r -Recurse -Depth 3 -Filter 'NapCatWinBootMain.exe' -ErrorAction SilentlyContinue)) {
            $candidates += (Split-Path $h.FullName -Parent)
        }
    }
    $good = @()
    foreach ($c in @($candidates | Select-Object -Unique)) {
        if (Test-NapCatRoot $c) {
            if (Test-NapCatQqBuild $c) { $good += $c }
            elseif (-not $ExistingOnly) { Warn ('跳过版本对不上的 NapCat：' + $c) }
            continue
        }
        $parent = Split-Path $c -Parent
        if ($parent -and (Test-NapCatRoot $parent)) { $good += $parent }
    }
    $good = @($good | Select-Object -Unique)
    if ($good.Count -ge 1) {
        $pick = $good[0]
        if ($good.Count -gt 1) {
            # 优先自带 QQ 的一体包，其次配置最全的
            $scored = @($good | ForEach-Object {
                [pscustomobject]@{ Path = $_; Score = $(if (Test-NapCatSelfContained $_) { 1000 } else { 0 }) + (Get-NapCatConfigDirs $_).Count * 10 - $_.Length / 1000 }
            })
            $pick = ($scored | Sort-Object Score -Descending)[0].Path
        }
        if (-not $ExistingOnly) {
            Ok ('找到现成的 NapCat：' + $pick)
            Info '如果要改用它自带的 QQ/NapCat，删掉这个目录或加 -NapCatDir 指定别的。'
        }
        return $pick
    }

    # 只是清点家底时到此为止，绝不触发下载
    if ($ExistingOnly) { return $null }

    if ($NapCatMode -eq 'shell') { return (Install-NapCatShell) }

    if ($NapCatMode -eq 'auto') {
        # 机器上已经有 QQ，就别下那 300 MB 的一体包了。
        # 官方 Shell 包只有 34 MB 左右，装完直接用现成的 QQ。
        $qq = Get-QqClientInfo
        if ($qq) {
            Info ('机器上已经有 QQ ' + $qq.Version + '：' + $qq.Root)
            Info '用官方 Shell 包（约 34 MB），省掉一体包里那 300 MB 的 QQ'
            $r = Install-NapCatShell
            if ($r) { return $r }
            Warn '用现成 QQ 这条路没走通，退回一体包（要下 300 MB 左右）'
        } else {
            # 没装 QQ：别默默下 334 MB。先说清楚两条路，让客户自己选。
            # （会用到这个工具的人，本来就是要"在 QQ 里跟大模型聊天"，几乎必定有 QQ。
            #   真没有的，装一个 QQ 比下 334 MB 快得多，也不用在机器上多养一套 QQ。）
            Say ''
            Warn '这台机器上没有装 QQ'
            Info 'NapCat 要挂在一个 QQ 客户端上才能跑，它自己不是 QQ。'
            Info '你自己装个 QQ 再来最省事：只要 34 MB，不用下 334 MB 的一体包。'
            Say ''
            if (-not $Quiet) {
                $ans = Read-Host '   还是要我现在下一体包（自带 QQ，约 334 MB，可能很慢）？(y/N)'
                if ($ans -notmatch '^[yY]') {
                    Fail '没有 QQ，装不了 NapCat' @"
两条路，任选一条：

  · 装个 QQ（推荐）：https://im.qq.com
    装完重跑本脚本，会自动走 Shell 包，只下 34 MB。

  · 用一体包（自带一整套 QQ）：重跑时加 -NapCatMode onekey
    要下 334 MB（0.95 + 300 + 34），网络差的时候会很久。
"@
                }
            }
        }
    }

    return (Install-NapCatOneKey)
}

# QQ NT 装在哪，它自己在注册表里记着；注册表没有的再按常见路径兜。
# （这地方以前硬编码过开发机的 D:\tools Software\QQ，换台机器就瞎了，别再那么干。）
function Get-QqClientInfo {
    $roots = @()

    foreach ($k in @(
            'HKLM:\SOFTWARE\WOW6432Node\Tencent\QQNT',
            'HKLM:\SOFTWARE\Tencent\QQNT',
            'HKCU:\Software\Tencent\QQNT'
        )) {
        try {
            $p = Get-ItemProperty $k -ErrorAction Stop
            if ($p -and $p.Install) { $roots += [string]$p.Install }
        } catch { }
    }

    # QQ 正在跑的话，进程路径最实在
    try {
        $qqProc = Get-Process -Name 'QQ' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($qqProc -and $qqProc.Path) { $roots += (Split-Path $qqProc.Path -Parent) }
    } catch { }

    $roots += @(
        "$env:ProgramFiles\Tencent\QQNT",
        "${env:ProgramFiles(x86)}\Tencent\QQNT",
        'C:\Program Files\Tencent\QQ',
        "$env:LOCALAPPDATA\Programs\Tencent\QQ"
    )

    foreach ($r in @($roots | Select-Object -Unique)) {
        if (-not $r) { continue }
        $v = Join-Path $r 'versions'
        if (-not (Test-Path $v)) { continue }
        $dirs = @(Get-ChildItem $v -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+-\d+$' } |
            Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -gt 0) { return [pscustomobject]@{ Root = $r; Version = $dirs[0].Name } }
    }
    return $null
}

function Assert-VersionMatch([string]$NapCatPath, $QqInfo) {
    Step '3.5' '校验 QQ 与 NapCat 版本'

    if (Test-NapCatSelfContained $NapCatPath) {
        Ok '这是一体包（自带 QQ），版本天生自洽，跳过对比'
        return
    }

    if (-not $QqInfo) {
        Warn '没找到 QQ 客户端安装目录（可能没装，或装在非常规位置）'
        Info '版本对齐跳过；一旦登录失败，优先怀疑版本不匹配。'
        return
    }
    Ok ('QQ 客户端：' + $QqInfo.Version + '   (' + $QqInfo.Root + ')')

    $qqBuild = $null
    if ($QqInfo.Version -match '(\d+\.\d+\.\d+)-(\d+)$') { $qqBuild = $Matches[2] }
    if (-not $qqBuild) { Warn '读不出 QQ 的 build 号，跳过对比'; return }

    $hit = Get-ChildItem $NapCatPath -Recurse -Depth 6 -Filter 'qqnt.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) { Info 'NapCat 里没有 qqnt.json，跳过版本对比'; return }

    $meta = Read-Json $hit.FullName
    $napBuild = [string]$meta.buildVersion
    Info ('NapCat 认的 QQ build：' + $napBuild + '；你装的是：' + $qqBuild)
    if ($napBuild -ne '' -and $napBuild -ne $qqBuild) {
        Warn '版本对不上 —— 这是“登录掉线 / 面板失效”的头号原因'
        Info '二选一：换一份对得上当前 QQ 的 NapCat；或把 QQ 降回对应版本。'
    } else {
        Ok '版本对得上'
    }
}

function Set-NapCatConfig([string]$NapCatPath, [string]$QQNumber, [int]$Port, [string]$Token) {
    Step 6 '把服务端信息写进 NapCat（反向 WS 客户端）'

    $dirs = @(Get-NapCatConfigDirs $NapCatPath)
    if ($dirs.Count -eq 0) { Fail '找不到 NapCat 的 config 目录' ('路径：' + $NapCatPath + '；NapCat 可能没装完整。') }

    $cfgDir = $null
    $target = $null
    foreach ($d in $dirs) {
        $hit = Get-ChildItem $d -Filter ('onebot11_*' + $QQNumber + '.json') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $cfgDir = $d; $target = $hit.FullName; break }
    }
    if (-not $cfgDir) {
        foreach ($d in $dirs) {
            $hit = Get-ChildItem $d -Filter 'onebot11_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $cfgDir = $d; $target = Join-Path $d ('onebot11_' + $QQNumber + '.json'); break }
        }
    }
    if (-not $cfgDir) { $cfgDir = $dirs[0]; $target = Join-Path $cfgDir ('onebot11_' + $QQNumber + '.json') }

    if (-not (Test-Path $cfgDir)) {
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Info ('配置目录原本不存在，已新建：' + $cfgDir + '（首次启动前就把客户端配好）')
    }
    Ok ('配置目录：' + $cfgDir)
    if ($dirs.Count -gt 1) { Info ('这机器上有 ' + $dirs.Count + ' 处 NapCat 配置，已选最匹配 QQ ' + $QQNumber + ' 的那处。') }

    $store = $null
    if (Test-Path $target) { Backup-File $target; $store = Read-Json $target }
    if (-not $store) {
        $store = [pscustomobject]@{
            network = [pscustomobject]@{
                httpServers = @(); httpSseServers = @(); httpClients = @(); websocketServers = @(); plugins = @()
                websocketClients = @()
            }
            musicSignUrl = ''; enableLocalFile2Url = $false; parseMultMsg = $false
            imageDownloadProxy = ''
            timeout = [pscustomobject]@{ baseTimeout = 10000; uploadSpeedKBps = 256; downloadSpeedKBps = 256; maxTimeout = 1800000 }
        }
    }
    if (-not $store.network) { $store | Add-Member -NotePropertyName network -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $store.network.websocketClients) {
        $store.network | Add-Member -NotePropertyName websocketClients -NotePropertyValue @() -Force
    }

    $clients = @($store.network.websocketClients)
    $mine = $clients | Where-Object { $_.name -eq 'dsh-deploy' } | Select-Object -First 1
    if (-not $mine) { $mine = $clients | Where-Object { $_.url -and ($_.url -match (':' + $Port + '(/|$)')) } | Select-Object -First 1 }
    if (-not $mine) {
        # 一次建全，不要建个只有 name 的空壳再去补字段
        $mine = [pscustomobject]@{
            name = 'dsh-deploy'; enable = $true; url = 'ws://127.0.0.1:' + $Port + '/ws'
            token = $Token; reportSelfMessage = $false; messagePostFormat = 'array'
            reconnectInterval = 30000; heartInterval = 30000; verifyCertificate = $true
        }
        $clients += $mine
    }

    # 一律 Add-Member：老 NapCat 配置里的客户端常常没有 enable/verifyCertificate 这些键，
    # 直接 $mine.enable = $true 会抛 "The property 'enable' cannot be found"。
    Set-Prop $mine 'enable' $true
    Set-Prop $mine 'url' ('ws://127.0.0.1:' + $Port + '/ws')
    Set-Prop $mine 'token' $Token
    Set-Prop $mine 'reportSelfMessage' $false
    Set-Prop $mine 'messagePostFormat' 'array'
    Set-Prop $mine 'reconnectInterval' 30000
    Set-Prop $mine 'heartInterval' 30000
    Set-Prop $mine 'verifyCertificate' $true
    $store.network.websocketClients = $clients

    # 本地 HTTP API：只给脚本自己发一条测试消息用，绑 127.0.0.1，不对外
    if (-not $store.network.httpServers) {
        $store.network | Add-Member -NotePropertyName httpServers -NotePropertyValue @() -Force
    }
    $httpServers = @($store.network.httpServers)
    $myHttp = $httpServers | Where-Object { $_.name -eq 'dsh-deploy' } | Select-Object -First 1
    if (-not $myHttp) {
        $myHttp = [pscustomobject]@{
            name = 'dsh-deploy'; enable = $true; host = '127.0.0.1'; port = $script:TestApiPort
            messagePostFormat = 'array'; enableForcePushEvent = $false; debug = $false; token = $Token
        }
        $httpServers += $myHttp
    }
    Set-Prop $myHttp 'enable' $true
    Set-Prop $myHttp 'host' '127.0.0.1'
    Set-Prop $myHttp 'port' $script:TestApiPort
    Set-Prop $myHttp 'token' $Token
    Set-Prop $myHttp 'messagePostFormat' 'array'
    $store.network.httpServers = $httpServers

    Write-Json $target $store

    # NapCat 面板密码跟着 AstrBot 走（webui.json 里是明文 token）
    if ($script:PanelPassword -and $cfgDir) {
        $webFile = Join-Path $cfgDir 'webui.json'
        if (Test-Path $webFile) {
            try {
                Backup-File $webFile
                $wj = Read-Json $webFile
                Set-Prop $wj 'token' $script:PanelPassword
                Write-Json $webFile $wj
                Ok 'NapCat 面板密码已同步'
            } catch {
                Warn ('改 NapCat 面板密码失败：' + $_.Exception.Message)
            }
        }
    }

    Ok ('已启用客户端：' + $mine.url)
    Ok '端口与 token 都和 AstrBot 一致'
    Ok ('本地测试接口：http://127.0.0.1:' + $script:TestApiPort)
}

# ── 面板密码 ──────────────────────────────────────────────────────────────
# AstrBot 的面板密码存成 pbkdf2_sha256$600000$盐$摘要（盐、摘要都是 hex），
# 校验逻辑见 astrbot/core/utils/auth_password.py；MD5 是历史兼容格式。
# NapCat 的 WebUI 用明文 token。两边统一成脚本生成的一个密码，省得客户去翻。
function New-PanelPassword {
    $u = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $l = 'abcdefghijkmnpqrstuvwxyz'
    $d = '23456789'
    $all = $u + $l + $d
    for ($try = 0; $try -lt 20; $try++) {
        $chars = @()
        for ($i = 0; $i -lt 10; $i++) { $chars += [string]$all[(Get-Random -Maximum $all.Length)] }
        $pw = -join $chars
        if ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '\d') { return ('Dsh' + $pw) }
    }
    return 'DshAstrBot2026'
}

function Get-Md5Hex([string]$Text) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    } finally { $md5.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-Pbkdf2Hash([string]$Password, [int]$Iterations = 600000) {
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $rng.Dispose()
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $key = $kdf.GetBytes(32)
    $saltHex = (($salt | ForEach-Object { $_.ToString('x2') }) -join '')
    $keyHex = (($key | ForEach-Object { $_.ToString('x2') }) -join '')
    return ('pbkdf2_sha256$' + $Iterations + '$' + $saltHex + '$' + $keyHex)
}

# NapCat 的 WebUI 认 /webui?token=xxx 这种链接，打开就自动填好令牌，不用手敲
function Get-NapCatLoginUrl([string]$BaseUrl, [string]$Token) {
    if (-not $BaseUrl) { $BaseUrl = 'http://127.0.0.1:6099' }
    $BaseUrl = $BaseUrl.TrimEnd('/')
    if (-not $Token) { return ($BaseUrl + '/webui') }
    return ($BaseUrl + '/webui?token=' + [Uri]::EscapeDataString($Token))
}

function Save-PanelCredentials([string]$Path, [string]$Password, [string]$NapCatUrl, [string]$NapCatToken) {
    try {
        $napLogin = Get-NapCatLoginUrl $NapCatUrl $NapCatToken
        $lines = @(
            'DSH-QQ 一键部署 —— 面板登录信息（照下面填就行）',
            ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
            '',
            '=== AstrBot 面板（有用户名和密码两栏）===',
            '地址：http://127.0.0.1:6185',
            '用户名一栏填：astrbot',
            ('密码一栏填：  ' + $Password),
            '',
            '=== NapCat 面板 ===',
            '打开这个链接会直接把令牌填好（不用手敲）：',
            ('  ' + $napLogin),
            ('  令牌（token）：' + $NapCatToken),
            '',
            '（两个都是本机服务；想换密码就重新跑一次部署脚本）'
        )
        [IO.File]::WriteAllText($Path, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

# 把模板里的人格写进客户的 AstrBot 数据库。
#
# 为什么不能只塞 cmd_config.json：AstrBot 4.x 的人格存在 data_v4.db 的 personas 表里，
# cmd_config.json 里那个 persona 字段是空的（我一开始就查错了地方）。
# 所以这里直接操作 SQLite —— 用 AstrBot 自己的 venv python，不额外装东西。
function Import-PersonaTemplate {
    $tpl = Join-Path $PSScriptRoot 'templates\personas.json'
    if (-not (Test-Path $tpl)) { return $false }

    $db = Join-Path $script:Root 'astrbot\data\data_v4.db'
    if (-not (Test-Path $db)) { return $false }

    $py = Join-Path $script:Root 'astrbot\.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { return $false }

    $script = Join-Path $env:TEMP ('import-persona-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.py')
    $code = @'
import sqlite3, json, sys
db, tpl = sys.argv[1], sys.argv[2]
rows = json.load(open(tpl, encoding="utf-8"))
if not rows:
    sys.exit(0)
c = sqlite3.connect(db)
c.row_factory = sqlite3.Row
exists = set(r[0] for r in c.execute("select persona_id from personas"))
cols = [r[1] for r in c.execute("PRAGMA table_info(personas)")]
for r in rows:
    use = {k: v for k, v in r.items() if k in cols and k != "id"}
    pid = use.get("persona_id", "default")
    if pid in exists:
        sets = ",".join([k + "=?" for k in use.keys() if k != "persona_id"])
        vals = [use[k] for k in use.keys() if k != "persona_id"]
        c.execute("update personas set " + sets + " where persona_id=?", vals + [pid])
    else:
        cs = ",".join(use.keys())
        ph = ",".join(["?"] * len(use))
        c.execute("insert into personas (" + cs + ") values (" + ph + ")", list(use.values()))
c.commit()
print("personas imported: " + str(len(rows)))
'@
    try {
        [IO.File]::WriteAllText($script, $code, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $py $script $db $tpl 2>&1
        if ($LASTEXITCODE -eq 0) {
            Info ('人格模板已写入：' + ($out -join ' '))
            return $true
        }
        Warn ('人格模板写入失败：' + ($out -join ' '))
        return $false
    } catch {
        Warn ('人格模板写入出错：' + $_.Exception.Message)
    } finally {
        Remove-Item $script -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Get-NapCatRunning([string]$NapCatPath) {
    return @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($NapCatPath, [StringComparison]::OrdinalIgnoreCase) })
}

# NapCat 会自己开一个控制台窗口，那个窗口默认拿的是系统代码页（中文机器上是 GBK），
# 而它打印的是 UTF-8 —— 两边对不上，中文就花屏。
# 办法：用一个只做两件事的包装脚本启动它（chcp 65001 + 原样执行），把窗口代码页钉死。

# 让 NapCat 下次启动时自动登录这个号（webui.json 里的 autoLoginAccount）。
# 目的：扫一次码拿到号之后，重启不必再扫第二次。
function Set-NapCatAutoLogin([string]$NapCatPath, [string]$QQNumber) {
    if (-not $QQNumber) { return $false }
    foreach ($d in @(Get-NapCatConfigDirs $NapCatPath)) {
        $f = Join-Path $d 'webui.json'
        if (-not (Test-Path $f)) { continue }
        try {
            $j = Read-Json $f
            Set-Prop $j 'autoLoginAccount' $QQNumber
            Write-Json $f $j
            return $true
        } catch { }
    }
    return $false
}

function Restart-NapCat([string]$NapCatPath) {
    # 杀干净再拉起来。之前只 Stop-Process，偶发杀不掉就变成两个实例抢 QQ，
    # 现象是“一直连不上”，很难查。
    for ($round = 1; $round -le 3; $round++) {
        $running = @(Get-NapCatRunning $NapCatPath)
        if ($running.Count -eq 0) { break }
        if ($round -eq 1) {
            Info ('重启 NapCat 让新配置生效（停掉 PID ' + (($running | ForEach-Object { $_.ProcessId }) -join ',') + '）')
        }
        foreach ($p in $running) {
            cmd /c ('taskkill /F /T /PID ' + $p.ProcessId) 2>&1 | Out-Null
        }
        Start-Sleep -Seconds 2
    }

    $left = @(Get-NapCatRunning $NapCatPath)
    if ($left.Count -gt 0) {
        Warn ('还有 ' + $left.Count + ' 个 NapCat 进程杀不掉（PID ' + (($left | ForEach-Object { $_.ProcessId }) -join ',') + '）')
        Warn '请手动在任务管理器里结束 NapCatWinBootMain.exe / QQ.exe，再重跑本脚本。'
        return $false
    }

    # 停了就要拉起来，不然配置写完了也没人读
    try {
        Start-NapCatBoot $NapCatPath
    } catch {
        Warn ('NapCat 拉不起来：' + $_.Exception.Message)
        return $false
    }
    Start-Sleep -Seconds 3
    return $true
}

function Test-NapCatConnected([int]$Port) {
    return [bool](Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
}

function Get-NapCatWebUi([string]$NapCatPath) {
    foreach ($d in @(Get-NapCatConfigDirs $NapCatPath)) {
        $f = Join-Path $d 'webui.json'
        if (-not (Test-Path $f)) { continue }
        try {
            $j = Read-Json $f
            $p = 6099
            if ($j.port) { $p = [int]$j.port }
            return [pscustomobject]@{ Url = ('http://127.0.0.1:' + $p); Token = [string]$j.token; Path = $f }
        } catch { }
    }
    return $null
}

function Open-QrFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { $p = Start-Process -FilePath $Path -PassThru; $script:QrViewers += $p; return $p } catch { }
    try { $p = Start-Process -FilePath 'mspaint.exe' -ArgumentList ('"' + $Path + '"') -PassThru; $script:QrViewers += $p; return $p } catch { }
    return $null
}

# 扫码成功后要能把我们打开的看图窗口关掉，不能让它一直杵在那儿
function Close-QrViewers {
    $n = 0
    foreach ($p in @($script:QrViewers)) {
        try {
            if ($p -and -not $p.HasExited) {
                [void]$p.CloseMainWindow()
                Start-Sleep -Milliseconds 400
                if (-not $p.HasExited) { $p.Kill() }
                $n++
            }
        } catch { }
    }
    $script:QrViewers = @()
    return $n
}

# 扫码这一步最容易让人懵，所以把话说满
function Show-QrCode([string]$Path, [string]$ExpectQQ) {
    Say ''
    Say '  ============================================================' 'Cyan'
    Say '   现在扫这张二维码 —— 请用【机器人小号】扫' 'Cyan'
    Say '  ============================================================' 'Cyan'
    Say ''
    Say '   第 1 步：打开手机 QQ → 右上角「+」→ 扫一扫'
    Say '   第 2 步：用你准备当机器人的【小号】扫，别用平时自己聊天的号'
    Say '   第 3 步：手机上会弹「确认登录」，点一下才算完 —— 只扫码不确认，它就一直等'
    Say ''
    Say ('   二维码文件：' + $Path) 'DarkGray'
    if (Open-QrFile $Path) {
        Say '   已经帮你把这张图打开了 —— 没弹出来就看上面这个路径，手动双击它。' 'Green'
    } else {
        Say '   ！自动打开失败：请手动双击上面这个路径。' 'Yellow'
    }
    Say ''
}

# 登录成功的可靠信号：NapCat 会给登录的号写一份 napcat_<QQ>.json（账号级配置）。
# 只看 TCP 连接是不够的——扫了别的号时，配置写在那个人名下，永远连不上。
function Get-NapCatLoginMarker([string]$NapCatPath) {
    $best = $null
    foreach ($d in @(Get-NapCatConfigDirs $NapCatPath)) {
        foreach ($f in @(Get-ChildItem $d -Filter 'napcat_*.json' -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch '^napcat_(\d{5,12})\.json$') { continue }
            if (-not $best -or $f.LastWriteTime -gt $best.Time) {
                $best = [pscustomobject]@{ QQ = $matches[1]; Time = $f.LastWriteTime; File = $f.FullName }
            }
        }
    }
    return $best
}

# 返回登录成功的 QQ 号；超时/中断返回 $null
function Wait-NapCatLogin([string]$NapCatPath, [string]$ExpectQQ, [int]$Port) {
    $start = Get-Date
    $before = Get-NapCatLoginMarker $NapCatPath

    if (Test-NapCatConnected $Port) {
        if ($before) { return $before.QQ }
        return $ExpectQQ
    }

    $deadline = $start.AddMinutes(6)
    $lastKey = ''
    $lastScan = [DateTime]::MinValue
    $lastBeat = 0
    $lastReopen = 0
    $reopenCount = 0
    $adoptedOld = $false
    $missCount = 0

    while ((Get-Date) -lt $deadline) {
        if ($script:InterruptRequested) { throw '用户已请求中断' }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds

        # 信号 1：出现比开始时间更新的账号配置 → 刚刚扫码登录成功
        $m = Get-NapCatLoginMarker $NapCatPath
        if ($m -and $m.Time -gt $start.AddSeconds(-2)) {
            [void](Close-QrViewers)
            return $m.QQ
        }
        # 信号 2：已经连上 AstrBot
        if (Test-NapCatConnected $Port) {
            [void](Close-QrViewers)
            if ($m) { return $m.QQ }
            return $ExpectQQ
        }
        # 信号 3：本来就是登录状态（没有新文件）。
        # 只在“没在展示二维码”时才认领，否则会把正在等扫码的流程抢跑。
        if (-not $adoptedOld -and -not $lastKey -and $m -and $elapsed -ge 90 -and $m.Time -gt $start.AddMinutes(-30)) {
            $adoptedOld = $true
            Info ('检测到这个号已经是登录状态：' + $m.QQ)
            [void](Close-QrViewers)
            return $m.QQ
        }

        # 每 2 秒找一次二维码，新出或更新就展示
        if (((Get-Date) - $lastScan).TotalSeconds -ge 2) {
            $lastScan = Get-Date
            $qr = Get-ChildItem $NapCatPath -Recurse -Filter 'qrcode.png' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($qr -and ((Get-Date) - $qr.LastWriteTime).TotalSeconds -lt 240) {
                $key = $qr.FullName + '|' + $qr.LastWriteTime.Ticks
                if ($key -ne $lastKey) {
                    $lastKey = $key
                    Show-QrCode $qr.FullName $ExpectQQ
                    $lastReopen = $elapsed
                    $reopenCount = 0
                }
            }
        }

        # 二维码可能被关掉了：每 90 秒再打开一次，最多 3 次
        if ($lastKey -and ($elapsed - $lastReopen) -ge 90 -and $reopenCount -lt 3) {
            $reopenCount++
            $lastReopen = $elapsed
            $qrPath = ($lastKey -split '\|')[0]
            if (Test-Path $qrPath) {
                Say ('   再帮你打开一次二维码（第 ' + $reopenCount + ' 次）') 'DarkGray'
                [void](Open-QrFile $qrPath)
            }
        }

        if (-not (Get-NapCatRunning $NapCatPath)) {
            # 注入过程中 bootmain 会短暂消失再回来（它要重新拉起自己），
            # 读一两次读不到是正常的。连着五六次都读不到，才认定真的没了。
            $missCount++
            if ($missCount -ge 6) {
                Warn 'NapCat 进程已经不在了（登录窗口是不是被关掉了？）'
                return $null
            }
        } else {
            $missCount = 0
        }

        if (($elapsed - $lastBeat) -ge 30) {
            $lastBeat = $elapsed
            if ($lastKey) { Info ('还在等你扫码…… 已等 ' + $elapsed + ' 秒 / 最多 360 秒（扫完还要在手机上点「确认登录」）') }
            else { Info ('NapCat 正在准备登录界面…… 已等 ' + $elapsed + ' 秒') }
        }
        Start-Sleep -Milliseconds 900
    }
    return $null
}

function Wait-NapCatConnected([int]$Port, [int]$TimeoutSec = 120) {
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)
    $lastBeat = -15
    while ((Get-Date) -lt $deadline) {
        if ($script:InterruptRequested) { throw '用户已请求中断' }
        if (Test-NapCatConnected $Port) { return $true }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if (($elapsed - $lastBeat) -ge 15) {
            $lastBeat = $elapsed
            Info ('等 NapCat 连上 AstrBot…… 已等 ' + $elapsed + ' 秒')
        }
        Start-Sleep -Milliseconds 900
    }
    return $false
}

# 启动 NapCat → 扫码 → 返回实际登录的 QQ 号（这才是准的，不是参数里那个）
# 直接调注入器，不经过 NapCat 自带的 launcher.bat。
# launcher.bat 中间那几步（net session 提权 → reg query 找 QQ → 拼参数）在某些机器上
# 会静默退出，bootmain 压根没被调用 —— 客户看到的就是"NapCat 一闪没影"，
# 可手动带参数跑 bootmain 一切正常。它真正需要的只有两个路径 + 五个环境变量，
# 那就自己设、自己调，少一层猜谜。
# ── 记住密码（免扫码登录）─────────────────────────────────────────────────
# NapCat 支持用环境变量直接登录：NAPCAT_ACCOUNT + NAPCAT_QUICK_PASSWORD，
# 不用扫码、也不会因为"登录态失效"掉线。
# 代价是 QQ 密码得留在客户机器上。所以：
#   · 用 Windows DPAPI 加密存（ConvertFrom-SecureString），绑定当前用户——
#     换台机器、换个用户拷过去都是一堆乱码；
#   · 启动瞬间仍要以明文写进 start-napcat-dsh.cmd（NapCat 只认环境变量），
#     这个窗口期很短，但确实存在。交互里会跟客户讲明白。
# ── 部署填过的信息，攒着下次用 ─────────────────────────────────────────────
# 客户重装一次就要重新敲一遍 QQ 号、API Key，谁都会烦。
# 这里把填过的存到 %LOCALAPPDATA%\DSH-QQ\deploy-config.json（不放在安装目录，卸载不会带走），下次部署开场先问要不要复用。
# API Key 和 QQ 密码都是敏感东西，用 Windows DPAPI 加密（绑定当前用户，
# 拷到别的机器上就是乱码）。主人号、机器人号不加密——它们本来就是公开信息。
function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    try {
        return (ConvertFrom-SecureString (ConvertTo-SecureString $Text -AsPlainText -Force))
    } catch { return '' }
}

function Unprotect-Text([string]$Cipher) {
    if (-not $Cipher) { return '' }
    try {
        $sec = $Cipher | ConvertTo-SecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return '' }
}

function Get-DeployConfig {
    $p = Join-Path $script:DataDir 'deploy-config.json'
    if (-not (Test-Path $p)) { return $null }
    try {
        $o = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            OwnerQQ    = [string]$o.OwnerQQ
            BotQQ      = [string]$o.BotQQ
            ApiKey     = (Unprotect-Text ([string]$o.ApiKeyEnc))
            QqPassword = (Unprotect-Text ([string]$o.QqPasswordEnc))
            SavedAt    = [string]$o.SavedAt
        }
    } catch { return $null }
}

# 只传要改的字段，其余沿用文件里的旧值
function Save-DeployConfig {
    param(
        [string]$OwnerQQ = '',
        [string]$BotQQ = '',
        [string]$ApiKey = '',
        [string]$QqPassword = ''
    )
    try {
        $p = Join-Path $script:DataDir 'deploy-config.json'
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        $oldOwner = ''; $oldBot = ''; $oldKeyEnc = ''; $oldPwEnc = ''
        if (Test-Path $p) {
            try {
                $cur = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
                $oldOwner = [string]$cur.OwnerQQ
                $oldBot = [string]$cur.BotQQ
                $oldKeyEnc = [string]$cur.ApiKeyEnc
                $oldPwEnc = [string]$cur.QqPasswordEnc
            } catch { }
        }
        if ($OwnerQQ) { $oldOwner = $OwnerQQ }
        if ($BotQQ) { $oldBot = $BotQQ }
        if ($ApiKey) { $oldKeyEnc = (Protect-Text $ApiKey) }
        if ($QqPassword) { $oldPwEnc = (Protect-Text $QqPassword) }

        $o = [ordered]@{
            OwnerQQ      = $oldOwner
            BotQQ        = $oldBot
            ApiKeyEnc    = $oldKeyEnc
            QqPasswordEnc = $oldPwEnc
            SavedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}
function Save-NapCatCred([string]$QQ, [string]$Password) {
    if (-not $QQ -or -not $Password) { return $false }
    try {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        $enc = ConvertFrom-SecureString $sec
        $p = Join-Path $script:DataDir 'napcat-cred.txt'
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        [IO.File]::WriteAllText($p, ($QQ + "`r`n" + $enc), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Get-NapCatCred {
    $p = Join-Path $script:DataDir 'napcat-cred.txt'
    if (-not (Test-Path $p)) { return $null }
    try {
        $lines = [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)
        if ($lines.Length -lt 2 -or -not $lines[0] -or -not $lines[1]) { return $null }
        $sec = $lines[1] | ConvertTo-SecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        return [pscustomobject]@{ QQ = $lines[0].Trim(); Password = $pw }
    } catch { return $null }
}

function Remove-NapCatCred {
    $p = Join-Path $script:DataDir 'napcat-cred.txt'
    Remove-Item $p -Force -ErrorAction SilentlyContinue
}

function Show-CredToggle {
    Step '记住密码' '开启 / 关闭免扫码登录'
    $cred = Get-NapCatCred
    if ($cred) { Ok ('当前：已开启（记住的号：' + $cred.QQ + '）') }
    else { Info '当前：已关闭（每次重启要扫码）' }

    Say ''
    Say '   1 = 开启（记住 QQ 密码，以后重启免扫码）' 'White'
    Say '   0 = 关闭（删掉密码，改回扫码登录）' 'White'
    Say ''
    Say '   密码用 Windows 自带的加密存，只有这台机器、这个用户能解开。' 'DarkGray'
    Say '   但启动那一瞬间，它会以明文出现在 NapCat 的进程环境里。' 'DarkGray'
    Say ''
    $c = Read-Host '   输入 1 或 0'

    switch ($c.Trim()) {
        '1' {
            $qqNum = Read-Host '   机器人 QQ 号'
            if ($qqNum -notmatch '^\d{5,12}$') { Fail 'QQ 号格式不对' '纯数字，5~12 位，比如 2093698989。' }
            $sec = Read-Host '   QQ 密码（输入时不显示）' -AsSecureString
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            if (-not $plain) { Fail '密码是空的' '什么都没改。' }
            if (Save-NapCatCred $qqNum $plain) {
                Say ''
                Ok '记住了。下次「启动.cmd」会拿它直接登录'
                Info '想立刻生效：先「停止.cmd」再「启动.cmd」'
            } else {
                Fail '存不下来' '可能没有写权限，或者 DPAPI 出了问题。'
            }
        }
        '0' {
            Remove-NapCatCred
            Say ''
            Ok '已关闭。下次启动会要求扫码登录'
        }
        default {
            Say ''
            Warn '没听懂，什么也没改。'
        }
    }
}
function Start-NapCatBoot([string]$NapCatPath) {
    $boot = Join-Path $NapCatPath 'NapCatWinBootMain.exe'
    $inject = Join-Path $NapCatPath 'NapCatWinBootHook.dll'
    if (-not (Test-Path $boot)) { Fail 'NapCat 主程序不见了' ('这个文件不在：' + $boot) }
    if (-not (Test-Path $inject)) { Fail 'NapCat 注入用的 DLL 不见了' ('这个文件不在：' + $inject) }

    # 一体包：QQ 就在 NapCat 目录里；Shell 包：用机器上装的那个 QQ
    $qqExe = Join-Path $NapCatPath 'QQ.exe'
    if (-not (Test-Path $qqExe)) {
        $qq = Get-QqClientInfo
        if (-not $qq) { Fail '找不到 QQ.exe，没法注入' '装个 QQ，或者用 -NapCatMode onekey 走自带 QQ 的一体包。' }
        $qqExe = Join-Path $qq.Root 'QQ.exe'
        if (-not (Test-Path $qqExe)) { Fail ('QQ 目录里没有 QQ.exe：' + $qq.Root) '装一个完整版的 QQ NT。' }
    }

    # 为什么不用 cmd 包装：
    #   批处理里 set "VAR=value" 遇到 & | < > % 会被拆行，转义怎么写都不保险
    #   （set "P=a^&b" 实测照样把一行拆成两条命令）。密码里这些符号太常见了。
    # 为什么不用不带重定向的 Start-Process：
    #   PS 5.1 走 ShellExecute 时，子进程不继承本进程改过的环境变量，
    #   bootmain 拿不到 NAPCAT_* 就空转——进程在、6099 永远不监听、也不报错。
    # 所以：给本进程设环境变量，再用带重定向的 Start-Process（这条路是 CreateProcess，
    # 环境变量能继承），密码全程不落盘。
    $envNames = @('NAPCAT_PATCH_PACKAGE', 'NAPCAT_LOAD_PATH', 'NAPCAT_INJECT_PATH', 'NAPCAT_LAUNCHER_PATH', 'NAPCAT_MAIN_PATH', 'NAPCAT_ACCOUNT', 'NAPCAT_QUICK_PASSWORD')
    $saved = @{}
    foreach ($n in $envNames) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

    $consoleLog = Join-Path $script:LogDir 'napcat-console.log'
    $consoleErr = Join-Path $script:LogDir 'napcat-console.err'

    try {
        [Environment]::SetEnvironmentVariable('NAPCAT_PATCH_PACKAGE', (Join-Path $NapCatPath 'qqnt.json'), 'Process')
        [Environment]::SetEnvironmentVariable('NAPCAT_LOAD_PATH', (Join-Path $NapCatPath 'loadNapCat.js'), 'Process')
        [Environment]::SetEnvironmentVariable('NAPCAT_INJECT_PATH', $inject, 'Process')
        [Environment]::SetEnvironmentVariable('NAPCAT_LAUNCHER_PATH', $boot, 'Process')
        [Environment]::SetEnvironmentVariable('NAPCAT_MAIN_PATH', (Join-Path $NapCatPath 'napcat.mjs'), 'Process')

        # 有存过的密码就走免扫码登录，没有就扫码
        $cred = Get-NapCatCred
        if ($cred) {
            [Environment]::SetEnvironmentVariable('NAPCAT_ACCOUNT', $cred.QQ, 'Process')
            [Environment]::SetEnvironmentVariable('NAPCAT_QUICK_PASSWORD', $cred.Password, 'Process')
            Info ('用记住的密码直接登录：' + $cred.QQ + '（失败会自动退回扫码）')
        } else {
            [Environment]::SetEnvironmentVariable('NAPCAT_ACCOUNT', $null, 'Process')
            [Environment]::SetEnvironmentVariable('NAPCAT_QUICK_PASSWORD', $null, 'Process')
        }

        # 必须带 -q <机器人号>：NapCat 在非交互环境（输出被重定向）下，
        # 不给 -q 会先列出"可用于快速登录的账号"，然后发现没人能选，直接退出——
        # 客户看到的就是"二维码都没出来，窗口就没了"。
        # 给了 -q：快速登录失败会退回二维码模式，老老实实停在那儿等扫码。
        $argList = @(('"' + $qqExe + '"'), ('"' + $inject + '"'))
        $botQQ = ''
        try {
            $savedCfg = Get-DeployConfig
            if ($savedCfg -and $savedCfg.BotQQ) { $botQQ = $savedCfg.BotQQ }
        } catch { }
        # 部署流程里问过的话，$QQ 就是它
        if (-not $botQQ -and $QQ -match '^\d{5,12}$') { $botQQ = $QQ }
        if (-not $botQQ) {
            # 配置里没有，就从 NapCat 已有的 onebot 配置文件名里猜（onebot11_<号>.json）
            try {
                $f1 = @(Get-ChildItem (Join-Path $NapCatPath 'config') -Filter 'onebot11_*.json' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending) | Select-Object -First 1
                if ($f1 -and $f1.Name -match 'onebot11_(\d+)\.json') { $botQQ = $matches[1] }
            } catch { }
        }
        if ($botQQ) {
            $argList += @('-q', $botQQ)
            Info ('带上机器人号：' + $botQQ + '（快速登录失败会自动退回扫码）')
        }

        Start-Process -FilePath $boot -ArgumentList $argList -WorkingDirectory $NapCatPath `
            -RedirectStandardOutput $consoleLog -RedirectStandardError $consoleErr `
            -WindowStyle Hidden | Out-Null
    } finally {
        foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }

    # 老版本留下的包装脚本，别再让它被误用
    $oldWrap = Join-Path $NapCatPath 'start-napcat-dsh.cmd'
    if (Test-Path $oldWrap) { Remove-Item $oldWrap -Force -ErrorAction SilentlyContinue }

    Ok ('注入器已启动（静默），目标 QQ：' + $qqExe)
}

function Start-NapCat([string]$NapCatPath, [string]$ExpectQQ, [int]$Port, [switch]$SkipPrompt) {
    Step 5 '启动 NapCat，用小号扫码登录'

    $boot = Join-Path $NapCatPath 'NapCatWinBootMain.exe'
    if (-not (Test-Path $boot)) {
        Fail 'NapCat 主程序不见了' ('这个文件不在：' + $boot + '`n重新部署一次，或者用 -NapCatDir 指到正确的目录。')
    }

    $running = @(Get-NapCatRunning $NapCatPath)
    if ($running.Count -gt 0) {
        Ok ('NapCat 已经在运行（PID ' + (($running | ForEach-Object { $_.ProcessId }) -join ',') + '）')
    } else {
        Say ''
        Say '  ------------------------------------------------------------' 'Cyan'
        if ($SkipPrompt) { Say '   再扫一次码（配置换成了新号，需要重新登录）' 'Cyan' }
        else { Say '   下一步要扫码登录，请准备好【机器人小号】' 'Cyan' }
        Say '  ------------------------------------------------------------' 'Cyan'
        Say '   · 用你准备当机器人的【小号】扫，别用平时自己聊天的号'
        Say '   · 脚本不预设是哪个号，扫完自动认；认出来之后会告诉你'
        Say '   · 扫完我会关掉二维码窗口，然后继续往下配置'
        Say ''
        if (-not $Quiet -and -not $SkipPrompt) {
            $ans = Read-Host '   准备好了按回车开始（输入 n 取消）'
            if ($ans -match '^[nN]') { Fail '已取消，什么都没有改动' '想装的时候重新跑一次就行。' }
        }

        try {
            Start-NapCatBoot $NapCatPath
            Ok 'NapCat 已启动（会拉起 QQ 登录窗口，别关它）'
        } catch {
            Fail 'NapCat 启动失败' ('错误：' + $_.Exception.Message + '`n路径：' + $boot + '`n可能是杀软拦了，把整个 NapCat 目录加白名单再试。' + "`n如果用的是机器上现成的 QQ（Shell 包），也可能 QQ 版本和 NapCat 对不上：重跑加 -NapCatMode onekey，改用自带 QQ 的一体包。")
        }
    }

    Say ''
    Say '   接下来：NapCat 拉起 QQ → 生成二维码 → 我自动打开。' 'White'
    Say '   出现二维码之前可能要等十几秒，别急，也别关窗口。' 'DarkGray'
    Say ''

    $qq = Wait-NapCatLogin $NapCatPath $ExpectQQ $Port
    if (-not $qq) {
        $web = Get-NapCatWebUi $NapCatPath
        $webHint = ''
        if ($web) { $webHint = "`n4) 去 NapCat 面板手动登录：$($web.Url)   （token：$($web.Token)）" }
        Fail '等了 6 分钟，没检测到登录成功' @"
按顺序排查：

  1) 二维码没看到 / 过期了：重跑一遍本脚本，会重新出码并自动打开
  2) NapCat 的登录窗口是不是被关掉了？关掉就得重跑
$webHint
  4) 杀软拦了注入（QQ 闪退 / 一直转圈）：把
     $NapCatPath
     整个目录加进白名单，再用管理员重跑
"@
    }

    Ok ('登录成功：' + $qq)
    return $qq
}

# ── 自检 / 守护 / 回滚 ────────────────────────────────────────────────────
function Send-OneBotPrivateMsg([int]$ApiPort, [string]$Token, [string]$ToQQ, [string]$Text) {
    $url = 'http://127.0.0.1:' + $ApiPort + '/send_private_msg?access_token=' + [Uri]::EscapeDataString($Token)
    $payload = [pscustomobject]@{
        user_id = [long]$ToQQ
        message = @(@{ type = 'text'; data = @{ text = $Text } })
    } | ConvertTo-Json -Depth 6 -Compress
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Timeout = 10000
    $req.ReadWriteTimeout = 10000
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream()
    $rs.Write($bytes, 0, $bytes.Length)
    $rs.Close()
    $resp = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Close() }
    } finally { $resp.Close() }
}

function Invoke-TestMessage($Token, [string]$BotQQ) {
    $owner = $OwnerQQ
    if (-not $owner -and -not $Quiet) {
        Say ''
        $owner = Read-Host '   输入你自己（主人）的 QQ 号，让机器人给你发条测试消息（回车跳过）'
    }
    if (-not $owner -or $owner -notmatch '^\d{5,12}$') {
        Info '跳过测试消息（没给主人号）。之后可以自己给小号发一句话验证。'
        return
    }
    if ($owner -eq $BotQQ) {
        Info '主人号和机器人号是同一个，跳过测试消息。'
        return
    }
    Step '测试' '让机器人给你发一条消息'
    try {
        $r = Send-OneBotPrivateMsg -ApiPort $script:TestApiPort -Token $Token -ToQQ $owner -Text '部署完成，这是一条自动测试消息。收到就说明整条链路通了。'
        if ($r -match '"status"\s*:\s*"ok"') {
            Ok ('已发送到 ' + $owner + '，去 QQ 里看看收到没有')
        } else {
            Warn ('接口返回了异常：' + $r)
        }
    } catch {
        Warn ('测试消息没发出去：' + $_.Exception.Message)
        Info '常见原因：NapCat 的本地 HTTP 接口被占用或没起来。不影响机器人本身，你自己给小号发句话也能验证。'
    }
}

function Open-Panel([string]$Url, [string]$Label) {
    if (-not $Url) { return }
    try {
        Start-Process $Url | Out-Null
        Ok ('已打开 ' + $Label + '：' + $Url)
    } catch {
        Info ('打不开浏览器，手动访问：' + $Url)
    }
}

function Invoke-SelfCheck([int]$Port, $Target) {
    Step 7 '自检'
    $bad = 0

    if (Test-PortListen $Port) { Ok ('AstrBot OneBot 端口 ' + $Port + ' 在听') }
    else { Warn ($Port.ToString() + ' 端口没在听'); $bad++ }

    $abProc = Get-AstrBotProcess
    if ($abProc.Count -gt 0) { Ok ('AstrBot 进程在（PID ' + (($abProc | ForEach-Object { $_.ProcessId }) -join ',') + '）') }
    else { Warn 'AstrBot 进程不在'; $bad++ }

    $ball = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
    if ($ball.Count -gt 0) { Ok ('NapCat 进程在（PID ' + (($ball | ForEach-Object { $_.ProcessId }) -join ',') + '）') }
    else { Warn 'NapCat 进程不在'; $bad++ }

    if (Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue) { Ok 'NapCat 和 AstrBot 连上了' }
    else { Warn '两边还没连上（没登录 / 端口不对 / token 不一致）'; $bad++ }

    if ($Target) { Info ('AstrBot 形态：' + $Target.Kind + '，配置：' + $Target.Config) }

    Say ''
    if ($bad -eq 0) { Say '自检通过：去 QQ 里给机器人发一句话试试。' 'Green' }
    else { Say ('自检有 ' + $bad + ' 项没过，按上面提示处理。') 'Yellow' }
    return $bad
}

# ── 选装插件 ──────────────────────────────────────────────────────────────
# 本脚本只负责装软件。插件是选装件：升级版的安装包里会多带一个
# plugin\install-plugin.ps1，看到它就交给它装；没有就说明是基础版，跳过。
# 这样"基础款 / 升级版"的差别只在包里有没有这个文件，部署脚本不用分支。
function Invoke-OptionalPluginInstaller($AstrBotTarget, [string]$NapCatRoot, [int]$Port, [string]$Owner) {
    $repoRoot = $PSScriptRoot
    if (-not $repoRoot) { $repoRoot = Split-Path -Parent $PSCommandPath }
    $installer = Join-Path $repoRoot 'plugin\install-plugin.ps1'

    if (-not (Test-Path $installer)) {
        Info '基础版：包里没有插件安装器，跳过选装插件'
        return
    }

    Step '7.5' '安装选装插件（Almost perfect）'
    if ($AstrBotTarget.Kind -eq 'launcher') {
        $dataDir = Join-Path $AstrBotTarget.Root 'core\data'
    } else {
        $dataDir = Join-Path $AstrBotTarget.Root 'data'
    }

    try {
        & $installer -AstrBotDataDir $dataDir -NapCatRoot $NapCatRoot -Port $Port -Owner $Owner
        if ($LASTEXITCODE -ne 0) {
            Warn '插件安装器返回了失败（不影响机器人本体）'
        }
    } catch {
        Warn ('插件安装出错：' + $_.Exception.Message + '（不影响机器人本体）')
    }
}

# 客户手里最后该剩下两样：能启动的东西、能卸掉的东西。
# 卸载入口的 .cmd 由安装脚本顺带拉一份；万一没拉成，这里再补一份——
# 装得进去却卸不掉，是最让人骂街的收场。
function Ensure-UninstallEntry {
    $parent = Split-Path $script:AsRoot -Parent
    if (-not $parent) { return }
    $target = Join-Path $parent '卸载.cmd'

    $needWrite = $true
    if (Test-Path $target) {
        try {
            $raw = [IO.File]::ReadAllText($target)
            # 从 GitHub 裸拉下来的是 LF 版，cmd 会把它切错行（能把 echo 切成 e + cho），
            # 所以只要含裸 LF 就重写一遍
            $needWrite = [bool]($raw -match "(?<!\r)\n")
        } catch { $needWrite = $true }
    }
    if (-not $needWrite) { return }

    $lines = @(
        '@echo off',
        'chcp 65001 >nul',
        'title DSH-QQ 一键卸载',
        'setlocal',
        'cd /d "%~dp0"',
        '',
        'rem 想只删某个组件：把最后那行的 %* 换成 -UninstallTarget 1（1=AstrBot 2=NapCat 3=插件 4=全删）',
        'set "PS1=%~dp0ds-as-nap\_install\deploy.ps1"',
        'if exist "%PS1%" goto run',
        '',
        'echo.',
        'echo    找不到部署脚本：%PS1%',
        'echo    先跑一次安装脚本；或者手动把 deploy.ps1 放到 ds-as-nap\_install\',
        'echo.',
        'pause',
        'exit /b 1',
        '',
        ':run',
        'powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Uninstall -InstallRoot "%~dp0ds-as-nap" %*',
        'set RESULT=%ERRORLEVEL%',
        'echo.',
        'pause',
        'exit /b %RESULT%'
    )
    try {
        [IO.File]::WriteAllLines($target, $lines, (New-Object System.Text.UTF8Encoding($false)))
        Info ('卸载入口已就位：' + $target)
    } catch {
        Warn ('卸载入口没写出来（' + $_.Exception.Message + '）；要卸载就跑本脚本加 -Uninstall')
    }
}

function Install-Watchdog {
    Step 8 '安装守护任务（每 5 分钟自检一次）'
    $taskName = 'DSH-QQ-Watchdog'
    $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -SelfCheck -Quiet'
    schtasks /Create /TN $taskName /TR ("powershell " + $taskArgs) /SC MINUTE /MO 5 /F | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok ('已创建计划任务：' + $taskName) }
    else { Warn '计划任务创建失败（可能需要管理员身份）' }
}

function Get-PathMb([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $it = Get-Item -LiteralPath $Path -Force
    if (-not $it.PSIsContainer) { return [double]$it.Length }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    return [double]$m.Sum
}

# 卸载：可选只删 AstrBot / 只删 NapCat / 只删插件 / 全删。
# 能力就在 deploy.ps1 里；客户那边看到的是安装时顺带拉下来的 卸载.cmd。
function Invoke-UninstallMenu {
    # 卸载前先停服务。文件被进程占着的时候删不干净——.venv 里的 dll、
    # napcat 的 node_modules、还有正在写的日志，都会留下半拉子残留，
    # 客户下次重装就撞上"目录已存在但内容不对"。
    Say ''
    Say '   先停掉正在跑的服务……' 'DarkGray'
    if (Stop-AstrBot) { Ok 'AstrBot 已停止' } else { Info 'AstrBot 本来没在跑' }
    if (Stop-AllNapCat) { Ok 'NapCat 已停止' } else { Info 'NapCat 本来没在跑' }
    Start-Sleep -Seconds 2

    $target = $UninstallTarget
    if ($target -eq 'ask') {
        Say ''
        Say '============================================================' 'Cyan'
        Say '   卸载：要删哪些？' 'Cyan'
        Say '============================================================' 'Cyan'
        Say ''
        Say '   1) 只删 AstrBot（本体 + 配置 + 插件都在里面）'
        Say '   2) 只删 NapCat（含它自带的那份 QQ）'
        Say '   3) 只删看门狗插件 Almost perfect'
        Say '   4) 全删（AstrBot + NapCat + 插件 + 日志缓存 + 历史遗留）'
        Say '   0) 退出'
        Say ''
        do { $c = Read-Host '   输入 1 / 2 / 3 / 4 / 0' } until ($c -match '^[0-4]$')
        switch ($c) {
            '0' { Say '   已退出，什么都没有改动。' 'Yellow'; return 0 }
            '1' { $target = 'astrbot' }
            '2' { $target = 'napcat' }
            '3' { $target = 'plugin' }
            '4' { $target = 'all' }
        }
    }

    $abDir = $script:AbDir
    $ncDir = $script:NcDir
    $plugDir = Join-Path $abDir 'data\plugins\almost_perfect'
    $legacy = @(
        (Join-Path $env:LOCALAPPDATA 'dsh-qq-deploy'),
        (Join-Path $env:APPDATA 'uv\tools\astrbot'),
        (Join-Path $env:USERPROFILE '.astrbot_launcher'),
        (Join-Path $env:USERPROFILE 'Desktop\NapCat.Shell.Windows.OneKey'),
        (Join-Path $env:USERPROFILE '.local\bin\astrbot.exe')
    )

    $todo = @()
    Say ''
    Say '   将要删除：' 'White'
    $add = {
        param($label, $path)
        $mb = Get-PathMb $path
        if ($mb -lt 0) { Say ('   · ' + $label + '：不存在（' + $path + '）') 'DarkGray'; return }
        Say ('   · ' + $label + '：{0:N1} MB  {1}' -f ($mb / 1MB), $path)
        $script:unTodo += @{ Path = $path }
    }
    $script:unTodo = @()

    switch ($target) {
        'plugin' { & $add '看门狗插件' $plugDir }
        'astrbot' { & $add 'AstrBot（含配置与插件）' $abDir }
        'napcat' { & $add 'NapCat（含自带 QQ）' $ncDir }
        'all' {
            & $add '整个安装目录' $script:AsRoot
            foreach ($p in $legacy) { & $add '历史遗留' $p }
        }
    }
    $todo = $script:unTodo

    if ($todo.Count -eq 0) { Say ''; Say '   没有要删的东西，可能已经删过了。' 'Yellow'; return 0 }

    $total = 0
    foreach ($t in $todo) { $s = Get-PathMb $t.Path; if ($s -gt 0) { $total += $s } }
    Say ''
    Say ('   合计约 {0:N1} MB' -f ($total / 1MB)) 'Yellow'

    if ($DryRun) { Say ''; Say '   -DryRun：只看不删。' 'Green'; return 0 }

    if (-not $Yes) {
        Say ''
        $a = Read-Host '   确认删除吗？不可撤销 (y/N)'
        if ($a -notmatch '^[yY]') { Say '   已取消，什么都没有改动。' 'Yellow'; return 0 }
    }

    Say ''
    Say '   先停相关进程……' 'DarkGray'
    if ($target -eq 'astrbot' -or $target -eq 'plugin' -or $target -eq 'all') {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq 'astrbot.exe' -or ($_.Name -eq 'python.exe' -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($abDir, [StringComparison]::OrdinalIgnoreCase))
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if ($target -eq 'napcat' -or $target -eq 'all') {
        Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object { cmd /c ('taskkill /F /T /PID ' + $_.ProcessId) 2>&1 | Out-Null }
    }
    Start-Sleep -Seconds 2

    $failed = 0
    foreach ($t in $todo) {
        try {
            if (Test-Path -LiteralPath $t.Path) { Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $t.Path) { Say ('   ✗ 没删干净：' + $t.Path) 'Red'; $failed++ }
            else { Say ('   √ 已删：' + $t.Path) 'Green' }
        } catch {
            Say ('   ✗ 删除失败：' + $t.Path) 'Red'
            Say ('     ' + $_.Exception.Message) 'DarkGray'
            $failed++
        }
    }

    if ($target -eq 'all') {
        # 任务不存在时 schtasks 会往 stderr 打 "ERROR: ..."，在 Stop 模式下会被当成异常，
        # 所以整体兜住：删不掉也不影响卸载结果
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $q = (schtasks /Query /TN 'DSH-QQ-Watchdog' 2>&1 | Out-String)
            if ($q -match 'DSH-QQ-Watchdog') {
                $null = (schtasks /Delete /TN 'DSH-QQ-Watchdog' /F 2>&1 | Out-String)
                Say '   √ 已删除计划任务：DSH-QQ-Watchdog' 'Green'
            }
        } catch {
        } finally {
            $ErrorActionPreference = $oldEap
        }
    }

    Say ''
    if (Test-Path $script:DataDir) { Say ('   填过的 QQ 号 / API Key / 密码还在：' + $script:DataDir) 'DarkGray'; Say '   （下次重装会自动问你用不用；想清掉就直接删这个目录）' 'DarkGray' }
    if ($failed -eq 0) { Say '   卸载完成。' 'Green'; return 0 }
    Say ('  有 ' + $failed + ' 项没删掉，通常是进程还占着文件。关掉相关窗口再试。') 'Yellow'
    return 1
}

# ── 环境检查 ───────────────────────────────────────────────────────────────
function Assert-Environment {
    Step 1 '检查运行环境'

    if ($PSVersionTable.PSVersion.Major -lt 5) { Fail ('PowerShell 版本太低（当前 ' + $PSVersionTable.PSVersion + '）') 'Windows 10/11 自带的 5.1 就够。' }
    Ok ('PowerShell ' + $PSVersionTable.PSVersion)

    if (-not [Environment]::Is64BitOperatingSystem) { Fail '当前是 32 位系统' 'QQ NT 只支持 64 位 Windows。' }
    Ok '64 位系统'

    if (-not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
    $drive = $script:Root.Substring(0, 1)
    $free = [math]::Round((Get-PSDrive -Name $drive).Free / 1GB, 1)
    if ($free -lt 3) { Fail ('磁盘剩余空间不足（' + $free + ' GB）') '至少留 3 GB：Python 3.12 + astrbot + NapCat + 日志。' }
    Ok ('磁盘剩余 ' + $free + ' GB')

    $inv = Get-LocalInventory
    if (-not $SkipNetworkCheck) { Test-NetworkProfile -Inventory $inv }
    else { Warn '按 -SkipNetworkCheck 跳过联网预检：下面哪步下载失败，别怪提示不早说' }

    Show-SecurityNotice

    if (-not (Test-IsAdmin)) { Warn '不是管理员：QQ 装在 Program Files 时 NapCat 注入可能失败，登不上就用管理员重跑。' }
}

# ── 面向客户的动作（-Action）────────────────────────────────────────────────
function Resolve-AstrBotExisting {
    if ($AstrBotDir -and (Test-Path (Join-Path $AstrBotDir 'core\main.py'))) {
        return [pscustomobject]@{ Kind = 'launcher'; Root = $AstrBotDir; Config = (Join-Path $AstrBotDir 'core\data\cmd_config.json') }
    }
    $found = @(Get-LauncherInstances)
    if ($found.Count -gt 0) {
        return [pscustomobject]@{ Kind = 'launcher'; Root = $found[0].FullName; Config = (Join-Path $found[0].FullName 'core\data\cmd_config.json') }
    }
    $cli = Get-AstrBotCli
    if ($cli) {
        $work = $WorkDir
        if (-not $work) { $work = $script:AbDir }
        return [pscustomobject]@{ Kind = 'cli'; Root = $work; Config = (Join-Path $work 'data\cmd_config.json'); Cli = $cli }
    }
    return $null
}

function Get-AnyNapCatRoot {
    $onekey = $script:NcDir
    if (Test-Path $onekey) {
        # Shell 包：BootMain 就在本层
        if (Test-Path (Join-Path $onekey 'NapCatWinBootMain.exe')) { return $onekey }
        $ready = @(Get-ChildItem $onekey -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'NapCatWinBootMain.exe') } |
            Sort-Object LastWriteTime -Descending)
        if ($ready.Count -gt 0) { return $ready[0].FullName }
    }
    foreach ($r in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if (-not (Test-Path $r)) { continue }
        foreach ($h in (Get-ChildItem $r -Recurse -Depth 3 -Filter 'NapCatWinBootMain.exe' -ErrorAction SilentlyContinue)) {
            return (Split-Path $h.FullName -Parent)
        }
    }
    return $null
}

function Stop-AllNapCat {
    # 用 taskkill /T 连子进程（QQ）一起收拾；Stop-Process 偶尔杀不干净，
    # 结果就是两个 NapCat 实例抢同一个 QQ，表现成“一直连不上”。
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $false }

    foreach ($p in $procs) {
        cmd /c ('taskkill /F /T /PID ' + $p.ProcessId) 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2

    $left = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }

    # 还有 NapCat 目录下残留的 QQ.exe，也一并清掉（不动你自己常用的 QQ）
    Start-Sleep -Milliseconds 500
    return $true
}

function Invoke-ActionCheck {
    Step '检查' '环境与依赖'
    Assert-Environment

    $ab = Resolve-AstrBotExisting
    if ($ab) { Ok ('AstrBot：' + $ab.Kind + ' @ ' + $ab.Root) } else { Warn '没找到 AstrBot（还没部署，或 PATH 没刷新）' }
    if ($ab -and (Test-Path $ab.Config)) { Ok 'AstrBot 配置存在' } elseif ($ab) { Warn 'AstrBot 配置还没生成（先启动一次）' }

    $nap = Get-AnyNapCatRoot
    if ($nap) { Ok ('NapCat：' + $nap) } else { Warn '没找到 NapCat（部署时会自动装一体包）' }

    $qq = Get-QqClientInfo
    if ($qq) { Ok ('QQ 客户端：' + $qq.Version) } else { Info '没检测到 QQ 客户端（一体包模式不需要）' }

    $port = $OneBotPort
    if ($ab -and (Test-Path $ab.Config)) {
        $j = Read-Json $ab.Config
        $pl = @($j.platform) | Where-Object { $_.type -eq 'aiocqhttp' } | Select-Object -First 1
        if ($pl -and $pl.ws_reverse_port) { $port = [int]$pl.ws_reverse_port }
    }
    if (Test-PortListen $port) { Ok ('OneBot 端口 ' + $port + ' 在听') } else { Info ('OneBot 端口 ' + $port + ' 当前没在听（没启动时正常）') }
    exit 0
}

# 面板密码保存在「面板密码.txt」里（部署时写的）。AstrBot 那边配置里存的是哈希，
# 拿不回明文，所以启动时要显式把它捞出来给客户看——不然客户只知道地址不知道密码。
function Get-SavedPanelPassword {
    $p = Join-Path $script:Root '面板密码.txt'
    if (-not (Test-Path $p)) { return '' }
    try {
        foreach ($line in (Get-Content $p -Encoding UTF8)) {
            if ($line -match '密码一栏填：\s*(\S+)') { return $matches[1] }
        }
    } catch { }
    return ''
}

# 启动完把两个面板都推到客户面前。
# NapCat 那边能直接带 token 进（塞在 URL 参数里），AstrBot 那边只能填用户名密码。
function Open-PanelsForCustomer {
    $pw = Get-SavedPanelPassword
    $napRoot = Get-AnyNapCatRoot
    $napUrl = 'http://127.0.0.1:6099'
    $napToken = ''
    if ($napRoot) {
        $web = Get-NapCatWebUi $napRoot
        if ($web) {
            if ($web.Url) { $napUrl = $web.Url }
            if ($web.Token) { $napToken = $web.Token }
        }
    }

    Say ''
    Say '   ┌─ AstrBot 面板（要用户名和密码两栏）─────────────' 'Cyan'
    Say '   │  地址：http://127.0.0.1:6185'
    Say '   │  用户名一栏填：astrbot' 'Yellow'
    if ($pw) { Say ('   │  密码一栏填：  ' + $pw) 'Yellow' }
    else { Say '   │  密码：看 ds-as-nap\面板密码.txt（没有就重跑一次部署）' 'Yellow' }
    Say '   └─────────────────────────────────────────────────' 'Cyan'

    if ($napToken) {
        Say ''
        Say '   NapCat 面板不用手敲令牌，链接会自动填好。' 'DarkGray'
        Open-Panel (Get-NapCatLoginUrl $napUrl $napToken) 'NapCat 面板'
    }

    Open-Panel 'http://127.0.0.1:6185' 'AstrBot 面板'

    if ($pw) {
        try {
            Set-Clipboard -Value $pw
            Say '   AstrBot 密码已经复制到剪贴板 —— 光标放进密码栏，Ctrl+V 就行。' 'Green'
        } catch { }
    }
    Say ''
}

function Invoke-ActionStart {
    Step '启动' '把服务拉起来'
    $ab = Resolve-AstrBotExisting
    if (-not $ab) { Fail '还没部署过' '先双击「一键部署.cmd」跑一次；或者用 -Action Deploy 手动部署。' }
    if (-not (Test-Path $ab.Config)) { Warn '还没生成配置：先跑一次「一键部署.cmd」' }

    Start-AstrBot $ab
    $port = $OneBotPort
    if (Test-Path $ab.Config) {
        $j = Read-Json $ab.Config
        $pl = @($j.platform) | Where-Object { $_.type -eq 'aiocqhttp' } | Select-Object -First 1
        if ($pl -and $pl.ws_reverse_port) { $port = [int]$pl.ws_reverse_port }
    }
    if (-not (Wait-Until { Test-PortListen $port } 120 ('AstrBot 打开 ' + $port + ' 端口'))) {
        Fail ('AstrBot 没打开 ' + $port + ' 端口') ("看日志：" + (Join-Path $script:LogDir 'astrbot.out.log') + "`n或者双击「查看日志.cmd」")
    }
    Ok ('AstrBot 就绪：' + $port)

    $nap = Get-AnyNapCatRoot
    if ($nap) {
        # 启动前先清场：避免上一次没退干净的 NapCat 和这次抢同一个 QQ
        if (Stop-AllNapCat) { Info '已先关掉旧的 NapCat 进程' }
        Start-NapCatBoot $nap
        Ok 'NapCat 已拉起'
    } else { Warn '没找到 NapCat：先跑一次「一键部署.cmd」' }

    # 拉起来 ≠ 连上了。注入器要先把 QQ 拖起来、自动登录、再建 WS，十几秒起步；
    # 不等这一步就自检，必然报「两边还没连上」，客户以为白装了。
    if ($nap) {
        if (Wait-NapCatConnected $port 90) {
            Ok 'NapCat 已连上 AstrBot'
        } else {
            # 没连上，最常见的原因是"要扫码"。NapCat 把二维码写在 cache\qrcode.png，
            # 直接弹出来给你，省得自己去 6099 面板里翻。
            $qr = @(Get-ChildItem $nap -Recurse -Filter 'qrcode.png' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending) | Select-Object -First 1
            if ($qr) {
                Info ('需要扫码登录，二维码已经打开：' + $qr.FullName)
                [void](Open-QrFile $qr.FullName)
            } else {
                Info '没找到二维码文件，可能是自动登录还在进行'
            }
            Warn 'NapCat 起来了，但 90 秒内没连上 AstrBot：扫一下二维码，或者去 6099 面板看连接状态'
        }
    }

    Invoke-SelfCheck $port $ab | Out-Null
    Open-PanelsForCustomer
    exit 0
}

# 停服务时顺带清掉"多出来的"QQ：NapCat 拉起来的那个（机器人号）要杀，
# 你自己开着的那个（主人号）必须留着——不然一按停止，你正聊着的 QQ 也没了。
# 区分办法不看 QQ 号（命令行里根本没有），看「谁把它拉起来的」：
#   你自己双击的   → 父进程 explorer
#   NapCat 拉起的  → 父进程 NapCatWinBootMain；bootmain 先退了就成孤儿，父进程找不到
# 后两种都算该杀的。
function Stop-LeftoverQq {
    $keepParents = @('explorer', 'StartMenuExperienceHost', 'ShellExperienceHost')
    $killed = 0
    $kept = 0

    # 只看主进程（Electron 的 renderer/gpu/utility 都带 --type=，别一个个去杀）
    $mains = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' })

    foreach ($q in $mains) {
        $parentName = ''
        try {
            $pp = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$q.ParentProcessId) -ErrorAction SilentlyContinue
            if ($pp) { $parentName = [string]$pp.Name }
        } catch { }
        $parentBase = $parentName -replace '\.exe$', ''

        if ($keepParents -contains $parentBase) { $kept++; continue }

        try {
            cmd /c ('taskkill /F /T /PID ' + $q.ProcessId) 2>&1 | Out-Null
            $killed++
        } catch { }
    }

    if ($killed -gt 0) { Ok ('清掉了 ' + $killed + ' 个多余的 QQ（NapCat 拉起来的）') }
    if ($kept -gt 0) { Info ($kept.ToString() + ' 个你自己开的 QQ 没动') }
    return $killed
}

function Invoke-ActionStop {
    Step '停止' '把服务关掉（数据保留）'
    if (Stop-AstrBot) { Ok 'AstrBot 已停止' } else { Info 'AstrBot 本来没在跑' }
    if (Stop-AllNapCat) { Ok 'NapCat 已停止' } else { Info 'NapCat 本来没在跑' }
    Stop-LeftoverQq | Out-Null
    say_stop_tip
    exit 0
}

function say_stop_tip {
    Info '数据都在，下次「一键启动.cmd」就能接着用'
}

function Invoke-ActionBackup {
    Step '备份' '把配置和聊天数据打包'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $script:Root 'backups'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $items = @()
    $ab = Resolve-AstrBotExisting
    if ($ab) {
        $dataDir = if ($ab.Kind -eq 'launcher') { Join-Path $ab.Root 'core\data' } else { Join-Path $ab.Root 'data' }
        if (Test-Path $dataDir) { $items += $dataDir }
    }
    $nap = Get-AnyNapCatRoot
    if ($nap) {
        foreach ($d in (Get-NapCatConfigDirs $nap)) { if (Test-Path $d) { $items += $d } }
    }
    if ($items.Count -eq 0) { Fail '没找到可备份的内容' '先部署一次再来备份。' }

    $zip = Join-Path $backupDir ("backup-$stamp.zip")
    try {
        Compress-Archive -Path $items -DestinationPath $zip -CompressionLevel Optimal -Force
    } catch {
        Fail ('打包失败：' + $_.Exception.Message) '可能文件被占用，先「停止.cmd」再备份。'
    }
    $mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Ok ('备份完成：' + $zip + '（' + $mb + ' MB）')

    $old = @(Get-ChildItem $backupDir -Filter 'backup-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10)
    foreach ($f in $old) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    if ($old.Count -gt 0) { Info ('保留最近 10 份，已清理 ' + $old.Count + ' 份旧备份') }
    exit 0
}

function Invoke-ActionLogs {
    Step '日志' 'AstrBot 输出（Ctrl+C 退出）'
    $logOut = Join-Path $script:LogDir 'astrbot.out.log'
    if (-not (Test-Path $logOut)) { Fail '还没有日志' ('这个文件还不存在：' + $logOut + '；先启动一次服务。') }
    Get-Content $logOut -Tail 40 -Wait
    exit 0
}

# ── 主流程 ─────────────────────────────────────────────────────────────────

try {
    Say ('=== ' + $script:AppName + ' ===') 'Cyan'
    Say ('时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Set-WindowTitle '启动中'

    Initialize-NetClient
    Enable-CtrlCGuard
    # 关掉控制台快速编辑：客户在窗口里点一下文字，输出就会被冻住，看着像卡死
    Set-QuickEdit $false

    if ($Uninstall) {
    # 卸载会把安装目录整个删掉，日志不能写在里面，改到临时目录
    $script:LogDir = $env:TEMP
    $script:LogFile = Join-Path $env:TEMP ('dsad-uninstall-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    exit (Invoke-UninstallMenu)
}

    # 双击两次会起两个部署，互相覆盖配置——直接拦下
    if ($Action -eq 'Deploy' -and -not $Probe -and -not $SelfCheck -and -not $Preflight) { Enter-DeployLock }

    # 上次没跑完？先把话说清楚，别让客户对着“装一半”犯迷糊
    if ($Action -eq 'Deploy' -and -not $Probe -and -not $SelfCheck -and -not $Preflight) {
        $prev = Get-PreviousRun
        if ($prev) {
            Say ''
            Warn ('检测到上一次部署没走完：卡在「' + $prev.stage + '」，时间 ' + $prev.at)
            Info '重跑会接着装，已经装好的部分不会重装；想从头来就先删掉安装目录。'
            if (-not $Quiet) {
                $ans = Read-Host '继续吗？(Y/n)'
                if ($ans -and $ans -notmatch '^[Yy]') { Say '已退出，什么都没有改动。'; exit 0 }
            }
            Say ''
        }
    }

    switch ($Action) {
        'Check'  { Invoke-ActionCheck }
        'Start'  { Invoke-ActionStart }
        'Stop'   { Invoke-ActionStop }
        'Backup' { Invoke-ActionBackup }
        'Logs'   { Invoke-ActionLogs }
        'SetCred' { Show-CredToggle; exit 0 }
        'Status' {
            $sp = $OneBotPort
            $sab = Resolve-AstrBotExisting
            if ($sab -and (Test-Path $sab.Config)) {
                $sj = Read-Json $sab.Config
                $spl = @($sj.platform) | Where-Object { $_.type -eq 'aiocqhttp' } | Select-Object -First 1
                if ($spl -and $spl.ws_reverse_port) { $sp = [int]$spl.ws_reverse_port }
            }
            $bad = Invoke-SelfCheck $sp $sab
            if ($bad -gt 0) { exit 1 } else { exit 0 }
        }
    }

    if ($SelfCheck) {
        $p = $OneBotPort
        $probeCfg = $null
        $found = @(Get-LauncherInstances)
        if ($found.Count -gt 0) { $probeCfg = Join-Path $found[0].FullName 'core\data\cmd_config.json' }
        elseif (Test-Path (Join-Path ($script:AbDir) 'data\cmd_config.json')) { $probeCfg = Join-Path ($script:AbDir) 'data\cmd_config.json' }
        if ($probeCfg -and (Test-Path $probeCfg)) {
            $j = Read-Json $probeCfg
            $pl = @($j.platform) | Where-Object { $_.type -eq 'aiocqhttp' } | Select-Object -First 1
            if ($pl -and $pl.ws_reverse_port) { $p = [int]$pl.ws_reverse_port }
        }
        $bad = Invoke-SelfCheck $p $null
        if ($bad -gt 0) { exit 1 } else { exit 0 }
    }

    Assert-Environment

    if ($Preflight) {
        Say ''
        Say '预检结束：该有的有、该通的通，就可以正式部署了。' 'Green'
        Say '（这一步没有改动任何文件；去掉 -Preflight 才是真部署）' 'DarkGray'
        exit 0
    }

    # 先把"能卸载"这件事钉死，再开始装。装到一半客户想撤，也有个入口。
    Ensure-UninstallEntry

    $ab = Resolve-AstrBot
    Initialize-AstrBotWorkdir $ab
    # 启动 NapCat 之前先问一句机器人号：NapCat 在非交互环境（输出被重定向）下，
    # 不给 -q 会列一遍"可登录账号"然后直接退出，客户看到的就是"二维码都没出来"。
    # 填了能少扫一次码；不填就靠扫码认，但得赌 NapCat 这次肯停下来等。
    if (-not $QQ -and -not $Quiet) {
        $cfgQ = Get-DeployConfig
        if ($cfgQ -and $cfgQ.BotQQ) { $QQ = $cfgQ.BotQQ }
    }
    if (-not $QQ -and -not $Quiet) {
        Say ''
        Say '  ┌─ 机器人 QQ 号（可选）────────────────────────' 'Cyan'
        Say '  │  你准备拿来当机器人的那个小号。' 'White'
        Say '  │  填了能少扫一次码；不填也行，扫完我自动认出来。' 'DarkGray'
        Say '  └───────────────────────────────────────────────' 'Cyan'
        $qIn = Read-Host '  机器人 QQ 号（回车 = 不知道，靠扫码识别）'
        if ($qIn -match '^\d{5,12}$') {
            $QQ = $qIn
            Save-DeployConfig -BotQQ $QQ | Out-Null
        }
    }

    $napRoot = Find-NapCat
    $qqInfo = Get-QqClientInfo
    Assert-VersionMatch $napRoot $qqInfo

    if ($Probe) {
        Step '3.6' '探测结果（-Probe：不写任何配置）'
        Ok ('AstrBot 形态：' + $ab.Kind)
        Ok ('AstrBot 根目录：' + $ab.Root)
        Info ('配置文件将是：' + $ab.Config + '（存在=' + (Test-Path $ab.Config) + '）')
        Ok ('NapCat 根目录：' + $napRoot)
        foreach ($d in (Get-NapCatConfigDirs $napRoot)) { Info ('NapCat 配置目录：' + $d) }
        if ($qqInfo) { Ok ('QQ 客户端：' + $qqInfo.Version + ' @ ' + $qqInfo.Root) }
        Say ''
        Say '探测结束，没有改动任何文件。去掉 -Probe 才是真部署。' 'Green'
        exit 0
    }

    # 机器人小号只有扫完码才知道，这里给的是"预期号"，可以留空
    # 机器人小号不用问：扫完码脚本自己就能认出来。
    # -QQ 只是"我已经知道是哪个号"时的加速提示（给了就能省掉一次重启/扫码）。
    if ($QQ -and $QQ -notmatch '^\d{5,12}$') { Fail ('-QQ 格式不对：' + $QQ) '只填数字，5~12 位；不填也行，扫码后自动识别。' }
    $hasQqHint = [bool]$QQ

    # 上次填过的信息，能复用就复用——客户每次重装都要重敲一遍，谁都会烦
    if (-not $Quiet) {
        $savedCfg = Get-DeployConfig
        if ($savedCfg -and ($savedCfg.OwnerQQ -or $savedCfg.ApiKey)) {
            Say ''
            Say '  ┌─ 这台机器上存过上次填的信息 ──────────────────' 'Cyan'
            if ($savedCfg.OwnerQQ) { Say ('  │  你的 QQ 号：' + $savedCfg.OwnerQQ) 'White' }
            if ($savedCfg.BotQQ) { Say ('  │  机器人号：  ' + $savedCfg.BotQQ) 'DarkGray' }
            if ($savedCfg.ApiKey) {
                $head = $savedCfg.ApiKey.Substring(0, [Math]::Min(7, $savedCfg.ApiKey.Length))
                Say ('  │  API Key：   ' + $head + '...（已加密）') 'DarkGray'
            }
            if ($savedCfg.QqPassword) { Say '  │  QQ 密码：   已记住（用于免扫码）' 'DarkGray' }
            Say ('  │  存于 ' + $savedCfg.SavedAt) 'DarkGray'
            Say '  └───────────────────────────────────────────────' 'Cyan'
            $useSaved = Read-Host '  直接复用吗？（1 = 用这些，0 = 重新填）'
            if ($useSaved -eq '1') {
                if (-not $OwnerQQ) { $OwnerQQ = $savedCfg.OwnerQQ }
                if (-not $QQ) { $QQ = $savedCfg.BotQQ }
                if (-not $ApiKey) { $ApiKey = $savedCfg.ApiKey }
                Ok '已填入，不用再敲了'
            }
        }
    }

    # 该问的是"主人号"：当管理员、收测试消息都要它
    if (-not $OwnerQQ -and -not $Quiet) {
        Say ''
        Say '  ┌─ 你的 QQ 号（主人号）────────────────────────' 'Cyan'
        Say '  │  填【你自己】平时用的那个 QQ，不是给机器人的小号。' 'White'
        Say '  │  机器人会把你设成管理员，装完还会主动给你发一条测试消息。' 'DarkGray'
        Say '  │  跳过也能装，但装完你得自己去 6185 面板里把管理员补上。' 'Yellow'
        Say '  └───────────────────────────────────────────────' 'Cyan'
        $OwnerQQ = Read-Host '  你的 QQ 号（纯数字，直接回车 = 先跳过）'
    }
    if ($OwnerQQ -and $OwnerQQ -notmatch '^\d{5,12}$') { Warn ('主人号格式看着不对：' + $OwnerQQ + '，先不管了') ; $OwnerQQ = '' }
    if ($OwnerQQ) { Save-DeployConfig -OwnerQQ $OwnerQQ | Out-Null }

    # 参数直接给的也算数，存下来——不然每次都得重新传
    if ($ApiKey) { Save-DeployConfig -ApiKey $ApiKey | Out-Null }
    if (-not $ApiKey -and -not $Quiet) {
        Say ''
        Say '  ┌─ 模型 API Key ────────────────────────────────' 'Cyan'
        Say '  │  机器人要用大模型才能回话，API Key 就是那把钥匙。' 'White'
        Say '  │  没有它也能装完，但机器人不会说话——得你自己去面板里补。' 'Yellow'
        Say '  └───────────────────────────────────────────────' 'Cyan'
        Say ''

        $knowsKey = Read-Host '  你知道自己的 API Key 吗？（1 = 知道，0 = 不知道，帮我打开申请页面）'
        if ($knowsKey -eq '1') {
            Say ''
            Say '  把 API Key 贴进来（右键就是粘贴）。' 'White'
            Say '  脚本会自动写进配置，装完机器人就能说话。' 'DarkGray'
            $ApiKey = Read-Host '  API Key（直接回车 = 装完自己去 6185 面板填）'
        } else {
            Say ''
            Say '  那我们先去申请一把，很快：' 'White'
            Say '    1. 下面打开的页面里登录或注册（手机号/微信都行）' 'DarkGray'
            Say '    2. 左侧点「API keys」→「创建 API key」' 'DarkGray'
            Say '    3. 名字随便填（比如 dsh），点「创建」' 'DarkGray'
            Say '    4. 点「复制」，把那串 sk- 开头的复制下来' 'DarkGray'
            Say '    5. 回到这个窗口，右键粘贴（或者按 Shift+Insert）' 'DarkGray'
            Say ''
            Say '  正在打开：https://platform.deepseek.com/api_keys' 'Cyan'
            try { Start-Process 'https://platform.deepseek.com/api_keys' } catch { Warn '浏览器没打开的话，手动复制上面这个地址去访问' }
            Say ''
            Say '  拿到以后粘在这里；不想现在弄就回车跳过，装完去 6185 面板里填。' 'DarkGray'
            $pasted = Read-Host '  API Key'
            if ($pasted -and $pasted.Trim().Length -ge 10) { $ApiKey = $pasted.Trim() }
        }

        if ($ApiKey) {
            $head = $ApiKey.Substring(0, [Math]::Min(7, $ApiKey.Length))
            Ok ('API Key 收到（' + $head + '...）')
            Save-DeployConfig -ApiKey $ApiKey | Out-Null
        } else {
            Warn '没填 API Key：装完机器人不会回话，记得去 6185 面板补上'
        }
    } elseif (-not $ApiKey -and $Quiet) {
        Info '静默模式：没给 -ApiKey，装完自己去面板补'
    }

    if (-not (Test-Path $ab.Config)) {
        Info '还没配置：先启动一次 AstrBot 让它生成默认配置'
        if (Stop-AstrBot) { Start-Sleep -Seconds 3 }
        Start-AstrBot $ab
        if (-not (Wait-Until { Test-Path $ab.Config } 120 'AstrBot 生成配置文件')) {
            Fail 'AstrBot 起了但没生成配置文件' ('看日志：' + (Join-Path $script:LogDir 'astrbot.out.log') + "`n常见原因：工作目录没写权限，或 astrbot 命令版本不对。")
        }
        Ok '配置已生成'
    }

    # 管理员给「主人号」：AstrBot 的管理指令应该由你来使，不是机器人自己
    $adminQQ = $OwnerQQ
    if (-not $adminQQ) { $adminQQ = $QQ }
    $ob = Set-AstrBotConfig $ab $adminQQ $ApiKey -GroupMode:$Group -Wake $WakeWord -Gid $GroupId

    # 立刻把密码落盘。配置里的哈希在这一刻已经换成新密码了，密码文件要是不跟着更新，
    # 中途任何一步失败都会留下"配置是新密码、文件是旧密码"的局面——客户照着文件输，
    # 怎么输都是错的（这是实测踩到的坑）。
    if ($ob -and $ob.PanelPassword) {
        try {
            Save-PanelCredentials (Join-Path $script:Root '面板密码.txt') $ob.PanelPassword '' ''
        } catch { }
    }

    # 人格不在 cmd_config.json 里，在 data_v4.db 的 personas 表里，单独灌进去
    if (-not (Import-PersonaTemplate)) { Info '没有人格模板（基础版就是这样，原版人格）' }

    # 插件是选装：包里带 install-plugin.ps1 就装，没带就是基础版
    Invoke-OptionalPluginInstaller $ab $napRoot $ob.Port $OwnerQQ | Out-Null

    Info '重启 AstrBot 让配置生效'
    if (Stop-AstrBot) { Start-Sleep -Seconds 3 }
    Start-AstrBot $ab

    if (-not (Wait-Until { Test-PortListen $ob.Port } 120 ('AstrBot 打开 ' + $ob.Port + ' 端口'))) {
        $tail = ''
        $logOut = Join-Path $script:LogDir 'astrbot.out.log'
        if (Test-Path $logOut) { $tail = (Get-Content $logOut -Tail 15 | Out-String) }
        Fail ('AstrBot 的 OneBot 端口 ' + $ob.Port + ' 没有起来') ("1) 看日志里平台适配器有没有报错`n2) 端口被占就换：-OneBotPort 8123（脚本会同步改 NapCat）`n日志末尾：`n" + $tail)
    }
    Ok ('AstrBot 服务端就绪：' + $ob.Port)

    # 5) 扫码。给了预期号就先写配置（扫对了只扫一次）；没给就先扫、扫完再配
    if (-not $KeepNapCatRunning) {
        Step '5.0' '先关掉正在运行的 NapCat'
        if (Stop-AllNapCat) { Ok '已关掉旧进程（多开抢 QQ 是“连不上”的头号原因）' }
        else { Info '本来就没有 NapCat 在跑' }

        if ($hasQqHint) { Set-NapCatConfig $napRoot $QQ $ob.Port $ob.Token }
        else { Info '没给机器人号：先扫码认出是哪个号，再写配置' }
        if (-not (Restart-NapCat $napRoot)) {
            Fail 'NapCat 重启失败，没法继续' '手动结束所有 NapCatWinBootMain.exe 和 QQ.exe，再重跑本脚本。'
        }

        $actualQQ = Start-NapCat $napRoot $QQ $ob.Port
        if (-not $actualQQ) { Fail '没有检测到登录成功' '重跑一次；扫码时别关 QQ 窗口。' }

        if (-not $hasQqHint) {
            $QQ = $actualQQ
            Say ''
            Ok ('扫码成功，机器人号是 ' + $QQ)
            Save-DeployConfig -BotQQ $QQ | Out-Null
            Set-NapCatConfig $napRoot $QQ $ob.Port $ob.Token
            if (Set-NapCatAutoLogin $napRoot $QQ) {
                Info '已记下这个号，重启后试着自动登录（不灵会让你再扫一次）'
            }
            if (-not (Restart-NapCat $napRoot)) {
                Fail 'NapCat 重启失败，没法继续' '手动结束所有 NapCatWinBootMain.exe 和 QQ.exe，再重跑本脚本。'
            }
            # 先给自动登录一个机会；不行再让客户补扫一次
            if (-not (Wait-NapCatConnected $ob.Port 45)) {
                Info '这台机器没能自动登录，需要再扫一次码（最后一次）'
                if (-not (Start-NapCat $napRoot $QQ $ob.Port -SkipPrompt)) {
                    Fail '第二次扫码没有成功' ('重跑本脚本，这次直接用 ' + $QQ + ' 扫。')
                }
            }
        } elseif ($actualQQ -ne $QQ) {
            Say ''
            Warn ('你扫的号是 ' + $actualQQ + '，预期的是 ' + $QQ)
            Info 'NapCat 按 QQ 号分文件存配置，写错号等于没写；下面改按实际扫的号重写'
            $QQ = $actualQQ
            Set-NapCatConfig $napRoot $QQ $ob.Port $ob.Token
            if (Set-NapCatAutoLogin $napRoot $QQ) {
                Info '已记下这个号，重启后试着自动登录（不灵会让你再扫一次）'
            }
            if (-not (Restart-NapCat $napRoot)) {
                Fail 'NapCat 重启失败，没法继续' '手动结束所有 NapCatWinBootMain.exe 和 QQ.exe，再重跑本脚本。'
            }
            if (-not (Wait-NapCatConnected $ob.Port 45)) {
                Info '这台机器没能自动登录，需要再扫一次码（最后一次）'
                if (-not (Start-NapCat $napRoot $QQ $ob.Port -SkipPrompt)) {
                    Fail '第二次扫码没有成功' ('重跑本脚本，这次直接用 ' + $QQ + ' 扫。')
                }
            }
        } else {
            # 扫的就是预期号：配置早就写好了，登录即连
            [void](Set-NapCatAutoLogin $napRoot $QQ)
        }

        if (-not (Wait-NapCatConnected $ob.Port 90)) {
            Fail 'NapCat 没有连上 AstrBot' @"
二维码已经扫过了，但它没连上来。按顺序看：
  1) NapCat 面板里的连接状态：http://127.0.0.1:6099
  2) AstrBot 的 token 和 NapCat 里的是否一致（重跑一次会自动对齐）
  3) 端口被占就换：-OneBotPort 8123
  4) 日志目录里有 astrbot.out.log，看看适配器有没有报错
"@
        }
        Ok 'NapCat 已连上 AstrBot（反向 WS 通）'
    } else {
        Info '按 -KeepNapCatRunning 跳过 NapCat 启动与扫码：配置等它下次启动才生效'
    }

    Invoke-SelfCheck $ob.Port $ab | Out-Null

    if ($InstallWatchdog) { Install-Watchdog }

    # 自检消息：让机器人主动给主人发一条，客户立刻能看到“活的”
    Invoke-TestMessage $ob.Token $QQ

    # 收尾一问：要不要记住密码，以后重启免扫码。
    # 只问一次——已经存过就不再啰嗦（想改密码就用「记住密码.cmd」关掉再开）。
    if (-not $Quiet -and $QQ -and -not (Get-NapCatCred)) {
        Say ''
        Say '   每次重启都要拿手机扫码，挺烦的。可以把这个号的密码记住，让 NapCat 直接登录。' 'White'
        Say '   · 密码用 Windows 自带的加密存，只有这台机器、这个用户能解开' 'DarkGray'
        Say '   · 但启动那一瞬间，它会以明文出现在一个临时脚本里' 'DarkGray'
        Say '   · 不记也行：每次重启扫一下码就是了' 'DarkGray'
        $ans = Read-Host '   要记住吗？(y/N)'
        if ($ans -match '^[yY]') {
            $sec = Read-Host '   输入这个机器人号的 QQ 密码（输入时不显示）' -AsSecureString
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            if ($plain -and (Save-NapCatCred $QQ $plain)) {
                Save-DeployConfig -QqPassword $plain | Out-Null
                Ok '记住了，下次重启不用扫码'
            } else {
                Warn '没存成功，下次还是扫码登录'
            }
        } else {
            Info '没记住。想改主意的话，重跑一次部署脚本会再问一遍'
        }
    }

    # 配置完成 → 报密码 → 打开两个面板
    $webNap = Get-NapCatWebUi $napRoot
    # AstrBot 密码和 NapCat 令牌是两个不同的东西，必须分开存
    # （之前共用一个变量，被 NapCat 的 token 顶掉，客户拿 token 去登 AstrBot 当然错）
    $astrBotPw = $script:PanelPassword
    $napToken = ''
    $napUrl = 'http://127.0.0.1:6099'
    if ($webNap) {
        $napUrl = $webNap.Url
        if ($webNap.Token) { $napToken = $webNap.Token }
    }
    $credFile = Join-Path $script:Root '面板密码.txt'
    $napLoginUrl = Get-NapCatLoginUrl $napUrl $napToken
    if ($astrBotPw -or $napToken) { Save-PanelCredentials $credFile $astrBotPw $napUrl $napToken }

    Say ''
    Say '  ============================================================' 'Green'
    Say '   配置完成 ✔' 'Green'
    Say '  ============================================================' 'Green'
    Say ''
    Say ('   机器人 QQ：' + $QQ)
    Say ''
    Say '   ┌─ 登录 AstrBot 面板（照这个填）──────────────' 'Cyan'
    Say '   │  地址：http://127.0.0.1:6185'
    Say '   │  用户名一栏填：astrbot' 'Yellow'
    Say ('   │  密码一栏填：  ' + $astrBotPw) 'Yellow'
    Say '   └─────────────────────────────────────────────' 'Cyan'
    Say ''
    Say '   ┌─ 登录 NapCat 面板 ──────────────────────────' 'Cyan'
    Say ('   │  自动填好令牌的链接：' + $napLoginUrl) 'Yellow'
    Say ('   │  令牌本身：' + $napToken) 'DarkGray'
    Say '   └─────────────────────────────────────────────' 'Cyan'
    Say ''
    if ($astrBotPw) { Say ('   这些都存了一份：' + $credFile) 'DarkGray' }
    Say ('   日志目录：' + $script:LogDir) 'DarkGray'
    Say ''
    Say '   正在帮你打开两个面板（没弹出就点上面的地址）……' 'DarkGray'
    if ($webNap) { Open-Panel $napLoginUrl 'NapCat 面板' }
    Open-Panel 'http://127.0.0.1:6185' 'AstrBot 面板'
    Say ''
    Say ('   AstrBot 登录提醒：用户名填 astrbot，密码填 ' + $astrBotPw) 'Yellow'
    # 面板只认浏览器 localStorage 里的令牌，没法从网址带密码进去；
    # 能做到最省事的是把密码塞进剪贴板，用户按一次 Ctrl+V。
    if ($astrBotPw) {
        try {
            Set-Clipboard -Value $astrBotPw
            Say '   密码已复制到剪贴板 —— 光标放进密码栏，按 Ctrl+V 就行。' 'Green'
        } catch {
            Say '   剪贴板不可用，照着上面手动输入。' 'DarkGray'
        }
    }
    Say ''
    Say '   接下来：用手机 QQ 给这个机器人发一句话试试（群里要先 @ 它）。' 'White'
    Say '   日常用「启动.cmd / 停止.cmd / 状态.cmd」，不用再跑这个部署脚本。' 'DarkGray'
    Say ''
    Clear-RunMarker
    Set-WindowTitle '部署完成'
    exit 0
}
catch {
    if ($script:InterruptRequested) {
        Say ''
        Say '已按你的意思中止。' 'Yellow'
        Say ('  卡住的阶段：' + $script:CurrentStage)
        Say ('  已经装好的东西都留着，重跑本脚本会接着装。')
        Say ('  日志：' + $script:LogFile)
        exit 130
    }
    Fail ('未预期的错误：' + $_.Exception.Message) ("这一条不在常见问题里，把日志发给懂行的人看：`n" + $script:LogFile)
}
finally {
    # 无论如何把关闭按钮还回去，别让客户对着关不掉的窗口发呆；锁也要放掉
    Set-CloseButton $true
    Set-QuickEdit $true
    Exit-DeployLock
}
