<#
  DJOneHub QDC507 模块 Windows 首次部署: 环境引导脚本.

  通常由同目录的 .bat 双击调用, 也可以手动执行:
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Action setup
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Action deploy --confirm-persistent-deploy
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Action usbcfg
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Action usbcfg --write --port COM8

  职责只有三件事:
    1. 定位或自动下载 Android platform-tools (adb.exe), 解压到本目录下的 platform-tools
    2. 定位 Python 3 (>= 3.8); usbcfg 动作按需安装 pyserial
    3. 把后面的参数原样交给对应的 Python 脚本, 不做任何额外解释或改写
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('deploy', 'usbcfg', 'setup')]
    [string]$Action,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }

# Python 输出中文时避免管道乱码.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Windows PowerShell 5.1 默认不开 TLS 1.2, 下载 dl.google.com 会失败.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

$PlatformToolsUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$PythonMinimum = '3.8'

function Write-Info([string]$Message) { Write-Host "[DJOneHub] $Message" }
function Write-Warn([string]$Message) { Write-Host "[DJOneHub] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[DJOneHub] $Message" -ForegroundColor Red }

function Invoke-Native {
    # $ErrorActionPreference = 'Stop' 会把原生命令写到 stderr 的内容变成终止错误,
    # 所以调用外部程序时先临时降级, 只取退出码, 由调用方决定怎么处理.
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) {
            & $Executable @Arguments 2>$null | Out-Null
        } else {
            & $Executable @Arguments
        }
        return $LASTEXITCODE
    } catch {
        return -1
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-RemoteFile([string]$Url, [string]$Destination) {
    $splat = @{ Uri = $Url; OutFile = $Destination; TimeoutSec = 600 }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $splat['UseBasicParsing'] = $true }
    try {
        Invoke-WebRequest @splat
        return
    } catch {
        Write-Warn "下载失败, 换 curl.exe 重试: $($_.Exception.Message)"
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        $code = Invoke-Native -Executable $curl -Arguments @(
            '-L', '--fail', '--retry', '3', '--connect-timeout', '30', '--silent', '--show-error',
            '--output', $Destination, $Url
        )
        if ($code -eq 0 -and (Test-Path $Destination)) { return }
    }
    throw "无法下载 $Url ; 请检查网络或代理后重试."
}

function Install-PlatformTools([string]$AdbPath) {
    $target = Split-Path -Parent $AdbPath
    Write-Info "未找到 adb.exe, 正在自动下载 Android platform-tools ..."
    $stamp = [Guid]::NewGuid().ToString('N')
    $zip = Join-Path ([IO.Path]::GetTempPath()) "platform-tools-$stamp.zip"
    $staging = Join-Path ([IO.Path]::GetTempPath()) "platform-tools-$stamp"
    try {
        Get-RemoteFile $PlatformToolsUrl $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        $inner = Join-Path $staging 'platform-tools'
        if (-not (Test-Path (Join-Path $inner 'adb.exe'))) {
            throw "下载到的压缩包结构异常, 缺少 platform-tools\adb.exe"
        }
        if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
        Copy-Item -Path (Join-Path $inner '*') -Destination $target -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $AdbPath)) { throw "platform-tools 解压后仍未找到 $AdbPath" }
}

function Resolve-PlatformTools {
    if ($env:DJONEHUB_ADB -and (Test-Path $env:DJONEHUB_ADB)) { return (Resolve-Path $env:DJONEHUB_ADB).Path }
    $candidates = @(
        (Join-Path $Root 'platform-tools\adb.exe'),
        (Join-Path $env:LOCALAPPDATA 'DJOneHub\platform-tools\adb.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    $onPath = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $errors = @()
    foreach ($candidate in $candidates) {
        try {
            Install-PlatformTools $candidate
            return $candidate
        } catch {
            $errors += "$candidate -> $($_.Exception.Message)"
        }
    }
    throw ("无法安装 platform-tools:`n" + ($errors -join "`n"))
}

function Resolve-Python {
    $candidates = New-Object System.Collections.ArrayList
    if ($env:DJONEHUB_PYTHON) { [void]$candidates.Add(@($env:DJONEHUB_PYTHON.Trim())) }
    [void]$candidates.Add(@('py', '-3'))
    [void]$candidates.Add(@('python'))
    [void]$candidates.Add(@('python3'))

    $probe = 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 9)'
    foreach ($candidate in $candidates) {
        $exe = $candidate[0]
        $exeArgs = @($candidate | Select-Object -Skip 1)
        $command = Get-Command $exe -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        if ($command.CommandType -ne 'Application') { continue }
        $code = Invoke-Native -Executable $command.Source -Arguments (@($exeArgs) + @('-c', $probe)) -Quiet
        if ($code -eq 0) {
            return @{ Exe = $command.Source; Args = $exeArgs }
        }
    }
    return $null
}

function Resolve-Pyserial($Python) {
    $exeArgs = @($Python.Args)
    if ((Invoke-Native -Executable $Python.Exe -Arguments ($exeArgs + @('-c', 'import serial')) -Quiet) -eq 0) {
        return $true
    }
    Write-Info "正在安装串口依赖 pyserial (只装到当前用户) ..."
    $attempts = @(
        @('-m', 'pip', 'install', '--user', '--disable-pip-version-check', '--no-input', 'pyserial'),
        @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', 'pyserial')
    )
    foreach ($attempt in $attempts) {
        if ((Invoke-Native -Executable $Python.Exe -Arguments ($exeArgs + $attempt)) -eq 0) { break }
        [void](Invoke-Native -Executable $Python.Exe -Arguments ($exeArgs + @('-m', 'ensurepip', '--default-pip')) -Quiet)
    }
    if ((Invoke-Native -Executable $Python.Exe -Arguments ($exeArgs + @('-c', 'import serial')) -Quiet) -eq 0) {
        Write-Info "pyserial 已就绪."
        return $true
    }
    return $false
}

Write-Host ""
Write-Host "DJOneHub QDC507 模块 Windows 首次部署工具" -ForegroundColor Cyan
Write-Host "包目录: $Root"
Write-Host ""

# ---- 1. adb ----
$adb = $null
if ($Action -eq 'deploy' -or $Action -eq 'setup') {
    $adb = Resolve-PlatformTools
    Write-Info "adb: $adb"
} else {
    try {
        $adb = Resolve-PlatformTools
        Write-Info "adb: $adb"
    } catch {
        Write-Warn "未准备 adb.exe; 继续执行, 只是写入后不做 ADB 复查."
    }
}

# ---- 2. Python ----
Write-Info "检查 Python 3 (>= $PythonMinimum) ..."
$python = Resolve-Python
if (-not $python) {
    Write-Host ""
    Write-Fail "未找到可用的 Python 3 (需要 >= $PythonMinimum)。"
    Write-Host "请先安装 Python 3: https://www.python.org/downloads/windows/"
    Write-Host "安装时务必勾选 Add python.exe to PATH, 然后重新双击本脚本。"
    exit 3
}
Write-Info ("Python: " + $python.Exe + " " + ($python.Args -join ' '))

if ($Action -eq 'usbcfg') {
    if (-not (Resolve-Pyserial $python)) {
        Write-Fail "pyserial 安装失败; 请手动执行: python -m pip install pyserial"
        exit 4
    }
}

if ($Action -eq 'setup') {
    Write-Host ""
    Write-Info "环境准备完成。接下来可以运行 Deploy-Module.bat (在此之前先跑一次 Write-USBConfig.bat --write)。"
    exit 0
}

# ---- 3. 交给 Python 脚本 ----
$scriptName = if ($Action -eq 'deploy') { 'deploy_qdc507_windows.py' } else { 'flash-usbcfg.py' }
$scriptPath = Join-Path $Root $scriptName
if (-not (Test-Path $scriptPath)) {
    Write-Fail "缺少脚本: $scriptPath (请完整解压分享包, 不要只复制单个文件)"
    exit 2
}
if ($adb) { $env:DJONEHUB_ADB = $adb }

$exeArgs = @($python.Args)
# 统一 UTF-8: 管道或重定向时 Python 不再按本机 ANSI 代码页输出, 中文不会乱码.
$env:PYTHONIOENCODING = 'utf-8'
Write-Host ""
Write-Info ("执行: " + $scriptName + " " + ($ScriptArgs -join ' '))
Write-Host ""

$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$code = 1
try {
    & $python.Exe @exeArgs $scriptPath @ScriptArgs
    $code = $LASTEXITCODE
} catch {
    Write-Fail "运行 $scriptName 失败: $($_.Exception.Message)"
} finally {
    $ErrorActionPreference = $previous
}
exit $code