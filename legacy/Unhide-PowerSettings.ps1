# ============================================================
#  Unhide-PowerSettings.ps1
#  由 PowerTuner 以管理员身份调用：把 Windows 默认隐藏的电源策略解锁
#  只影响可见性（Attributes），不改变任何策略数值
#  用法：powershell -ExecutionPolicy Bypass -File Unhide-PowerSettings.ps1 [-Hide]
# ============================================================
param(
    [switch]$Hide
)

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot
$resultPath = Join-Path $scriptDir 'unhide.result.txt'
$logPath = Join-Path $scriptDir 'PowerTuner.log'

function Save-Result {
    param([string]$Text)
    try { Set-Content -Path $resultPath -Value $Text -Encoding UTF8 } catch { }
    try {
        $line = "[{0}] Unhide: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -Path $logPath -Value $line -Encoding UTF8
    }
    catch { }
}

# ---- 权限检查 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Save-Result '失败：没有管理员权限'
    exit 2
}

# 值得解锁的隐藏项（按注册表里的英文名匹配，与系统语言无关）
$patterns = @(
    'boost mode'
    'boost policy'
    'core parking'
    'idle disable'
    'idle time check'
    'idle demote threshold'
    'idle promote threshold'
    'performance time check'
    'increase threshold'
    'decrease threshold'
    'increase policy'
    'decrease policy'
    'increase time'
    'decrease time'
    'system cooling policy'
    'unattended sleep timeout'
    'console lock display off timeout'
    'connectivity in standby'
    'allow standby states'
    'usb 3 link power management'
    'energy saver'
    'processor performance history'
)

function Get-PlainName {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $t = $Raw.Trim()
    $m = [regex]::Match($t, '^@[^,]+,-?\d+,(.*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $t
}

function Test-Interesting {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $lower = $Name.ToLowerInvariant()
    foreach ($p in $patterns) { if ($lower.Contains($p)) { return $true } }
    return $false
}

# ---- 收集目标 ----
$root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings'
$targets = New-Object System.Collections.ArrayList

foreach ($sub in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
    foreach ($set in (Get-ChildItem -Path $sub.PSPath -ErrorAction SilentlyContinue)) {
        $sk = Get-Item -Path $set.PSPath -ErrorAction SilentlyContinue
        if (-not $sk) { continue }
        $name = Get-PlainName ([string]$sk.GetValue('FriendlyName'))
        if (-not (Test-Interesting -Name $name)) { continue }
        $null = $targets.Add([pscustomobject]@{
                Sub  = $sub.PSChildName
                Id   = $set.PSChildName
                Name = $name
                Path = $set.PSPath
            })
    }
}

if ($targets.Count -eq 0) {
    Save-Result '没有找到需要解锁的项目'
    exit 0
}

# ---- 执行 ----
$ok = 0
$fallback = 0
$fail = 0

foreach ($t in $targets) {
    if ($Hide) {
        $null = & powercfg /attributes $t.Sub $t.Id '+ATTRIB_HIDE' 2>&1
        $ok++
        continue
    }

    # 官方命令：-ATTRIB_HIDE 表示取消隐藏
    $null = & powercfg /attributes $t.Sub $t.Id '-ATTRIB_HIDE' 2>&1

    $attr = $null
    try { $attr = (Get-ItemProperty -Path $t.Path -Name Attributes -ErrorAction SilentlyContinue).Attributes } catch { }

    if ($null -eq $attr -or -not ($attr -band 2)) {
        # 命令未生效时直接写注册表兜底（2 = 显示）
        try {
            if ($null -eq $attr) {
                $null = New-ItemProperty -Path $t.Path -Name Attributes -Value 2 -PropertyType DWord -Force -ErrorAction Stop
            }
            else {
                $null = Set-ItemProperty -Path $t.Path -Name Attributes -Value 2 -Force -ErrorAction Stop
            }
            $fallback++
            $ok++
        }
        catch {
            $fail++
        }
    }
    else {
        $ok++
    }
}

if ($Hide) {
    Save-Result ("已重新隐藏 " + $ok + " 项")
}
else {
    $msg = "已解锁 $ok 项隐藏设置"
    if ($fallback -gt 0) { $msg += "（其中 $fallback 项通过注册表兜底完成）" }
    if ($fail -gt 0) { $msg += "，$fail 项失败" }
    Save-Result $msg
}

exit 0
