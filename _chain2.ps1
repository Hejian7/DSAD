$ErrorActionPreference = 'Stop'
$src = 'A:\true porject\DSAD\deploy.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$want = @(
 'Write-Log','Say','Step','Ok','Info','Warn','Fail','Set-WindowTitle','Set-Prop',
 'Read-LogTail','Wait-ProcessWithProgress','Get-FileWithProgress','Get-FileFromMirrors',
 'Get-TextWithTimeout','Add-PathEntry','Get-UvOnPath','Get-UvWheelFromIndex','Ensure-Uv',
 'Get-Python312Path','Install-Python312','Install-AstrBotViaUv','Get-AstrBotCli'
)
$sb = New-Object System.Text.StringBuilder
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $f.Name) { [void]$sb.AppendLine($f.Extent.Text) }
}
Invoke-Expression $sb.ToString()

$base = 'A:\true porject\DSAD\ds-as-nap'
$script:AsRoot = $base
$script:AbDir = Join-Path $base 'astrbot'
$script:NcDir = Join-Path $base 'napcat'
$script:PyDir = Join-Path $base 'python'
$script:UvDir = Join-Path $base 'uv'
$script:Root = $base
$script:LogDir = Join-Path $base 'logs'
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
$script:LogFile = Join-Path $script:LogDir 'chain2.log'
$script:Quiet = $false
$script:ProxyUrl = $null
$script:Net = @{}
$script:InterruptRequested = $false

Write-Host '===== 1) uv ====='
$uv = Ensure-Uv
Write-Host ('uv = ' + $uv)
Write-Host ''
Write-Host '===== 2) Python 3.12 ====='
$py = Get-Python312Path
Write-Host ('现有 = [' + $py + ']')
if (-not $py) { $py = Install-Python312 }
Write-Host ('python = [' + $py + ']')
if ($py) { & $py --version }
Write-Host ''
Write-Host '===== 3) venv + astrbot ====='
$ok = Install-AstrBotViaUv
Write-Host ('结果 = ' + $ok)
Write-Host ('CLI = [' + (Get-AstrBotCli) + ']')