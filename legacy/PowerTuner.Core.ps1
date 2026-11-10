# ============================================================
#  PowerTuner.Core.ps1
#  数据层：读取 / 解析 / 写入 Windows 电源策略（不依赖图形界面）
#  由 PowerTuner.ps1 点引入，也可单独点引入做命令行验证
# ============================================================

$script:SettingIndex = @{}
$script:SettingsCache = $null
$script:SchemesCache = $null

# ---------- 调用 powercfg ----------
function Invoke-PowerCfg {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & powercfg @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = @()
    foreach ($line in @($output)) {
        if ($null -eq $line) { continue }
        $text += [string]$line
    }
    return [pscustomobject]@{ Output = $text; Code = $code }
}

# ---------- 电源方案列表 ----------
function Get-PowerSchemes {
    param([switch]$Refresh)

    if ($script:SchemesCache -and -not $Refresh) { return $script:SchemesCache }

    $res = Invoke-PowerCfg -Arguments @('/list')
    $list = New-Object System.Collections.ArrayList
    $re = [regex]'GUID\s*[:：]\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*(?:\((.*?)\))?\s*(\*)?\s*$'

    foreach ($line in $res.Output) {
        $m = $re.Match($line)
        if (-not $m.Success) { continue }
        $name = $m.Groups[2].Value
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $m.Groups[1].Value }
        $null = $list.Add([pscustomobject]@{
                Guid   = $m.Groups[1].Value
                Name   = $name.Trim()
                Active = ($m.Groups[3].Value -eq '*')
            })
    }

    # powercfg /list 的星号在行尾，某些语言下位置有差异，做一次兜底
    if ($list.Count -gt 0 -and -not ($list | Where-Object { $_.Active })) {
        $r2 = Invoke-PowerCfg -Arguments @('/getactivescheme')
        if ($r2.Code -eq 0 -and $r2.Output.Count -gt 0) {
            $m2 = $re.Match([string]$r2.Output[0])
            if ($m2.Success) {
                foreach ($s in $list) { if ($s.Guid -eq $m2.Groups[1].Value) { $s.Active = $true } }
            }
        }
    }

    $script:SchemesCache = $list
    return $list
}

function Get-ActiveScheme {
    $schemes = Get-PowerSchemes -Refresh
    $active = $schemes | Where-Object { $_.Active } | Select-Object -First 1
    if (-not $active) { $active = $schemes | Select-Object -First 1 }
    return $active
}

function Set-ActiveScheme {
    param([Parameter(Mandatory = $true)][string]$Guid)
    $res = Invoke-PowerCfg -Arguments @('/setactive', $Guid)
    $script:SettingsCache = $null
    return $res.Code -eq 0
}

# ---------- 解析当前方案的全部设置 ----------
function Convert-HexToInt {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt32($Matches[1], 16) }
    $parsed = 0
    if ([int]::TryParse($t, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-PowerSettings {
    param([switch]$Refresh)

    if ($script:SettingsCache -and -not $Refresh) { return $script:SettingsCache }

    $res = Invoke-PowerCfg -Arguments @('/query', 'SCHEME_CURRENT')
    if ($res.Code -ne 0) { throw "读取电源策略失败 (powercfg /query 返回 $($res.Code))" }

    $subName = ''
    $subGuid = ''
    $cur = $null
    $pendingIdx = $null
    $list = New-Object System.Collections.ArrayList

    $reEntity = [regex]'^(?<label>.*?)\s*GUID\s*[:：]\s*(?<guid>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*(?:\((?<name>.*)\))?\s*$'
    $reAlias = [regex]'^(?:GUID\s*别名|GUID\s*Alias|别名|Alias)\s*[:：]\s*(?<v>\S+)\s*$'
    $reMin = [regex]'^(?:最小可能的设置|Minimum Possible Setting)\s*[:：]\s*(?<v>.+)$'
    $reMax = [regex]'^(?:最大可能的设置|Maximum Possible Setting)\s*[:：]\s*(?<v>.+)$'
    $reInc = [regex]'^(?:可能的设置增量|Possible Setting Increment)\s*[:：]\s*(?<v>.+)$'
    $reUnit = [regex]'^(?:可能的设置单位|Possible Setting Units?)\s*[:：]\s*(?<v>.+)$'
    $rePIdx = [regex]'^(?:可能的设置索引|Possible Setting Index)\s*[:：]\s*(?<v>.+)$'
    $rePName = [regex]'^(?:可能的设置友好名称|Possible Setting Friendly Name)\s*[:：]\s*(?<v>.+)$'
    $reAc = [regex]'^(?:当前交流电源设置索引|Current AC Power Setting Index)\s*[:：]\s*(?<v>.+)$'
    $reDc = [regex]'^(?:当前直流电源设置索引|Current DC Power Setting Index)\s*[:：]\s*(?<v>.+)$'

    foreach ($raw in $res.Output) {
        $line = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $m = $reEntity.Match($line)
        if ($m.Success) {
            $label = $m.Groups['label'].Value
            $guid = $m.Groups['guid'].Value
            $name = $m.Groups['name'].Value

            if ($label -match '电源方案|Power Scheme') {
                continue
            }
            elseif ($label -match '子组|Subgroup|SUB_GROUP') {
                $subGuid = $guid
                $subName = $name
                $cur = $null
                continue
            }
            else {
                $cur = [pscustomobject]@{
                    Id         = $guid
                    Name       = $name
                    Alias      = ''
                    Sub        = $subGuid
                    SubName    = $subName
                    Unit       = ''
                    Min        = $null
                    Max        = $null
                    Increment  = $null
                    Options    = (New-Object System.Collections.ArrayList)
                    AcValue    = $null
                    DcValue    = $null
                    Kind       = 'text'
                }
                $pendingIdx = $null
                $null = $list.Add($cur)
                continue
            }
        }

        if ($null -eq $cur) { continue }

        $mm = $reAlias.Match($line)
        if ($mm.Success) { $cur.Alias = $mm.Groups['v'].Value; continue }

        $mm = $reMin.Match($line)
        if ($mm.Success) { $cur.Min = Convert-HexToInt $mm.Groups['v'].Value; continue }

        $mm = $reMax.Match($line)
        if ($mm.Success) { $cur.Max = Convert-HexToInt $mm.Groups['v'].Value; continue }

        $mm = $reInc.Match($line)
        if ($mm.Success) { $cur.Increment = Convert-HexToInt $mm.Groups['v'].Value; continue }

        $mm = $reUnit.Match($line)
        if ($mm.Success) { $cur.Unit = $mm.Groups['v'].Value.Trim(); continue }

        $mm = $rePIdx.Match($line)
        if ($mm.Success) {
            $pendingIdx = Convert-HexToInt $mm.Groups['v'].Value
            continue
        }

        $mm = $rePName.Match($line)
        if ($mm.Success) {
            $optName = $mm.Groups['v'].Value.Trim()
            if ($null -ne $pendingIdx) {
                $null = $cur.Options.Add([pscustomobject]@{ Index = $pendingIdx; Name = $optName })
                $pendingIdx = $null
            }
            continue
        }

        $mm = $reAc.Match($line)
        if ($mm.Success) { $cur.AcValue = Convert-HexToInt $mm.Groups['v'].Value; continue }

        $mm = $reDc.Match($line)
        if ($mm.Success) { $cur.DcValue = Convert-HexToInt $mm.Groups['v'].Value; continue }
    }

    # 判定控件形态
    foreach ($s in $list) {
        $opts = @($s.Options)
        if ($opts.Count -ge 2) {
            $boolish = $false
            if ($opts.Count -eq 2) {
                $n0 = $opts[0].Name; $n1 = $opts[1].Name
                $pattern = '^(关闭|开启|已禁用|已启用|禁用|启用|Off|On|Disabled|Enabled|允许|不允许|否|是)$'
                if ($n0 -match $pattern -and $n1 -match $pattern) { $boolish = $true }
            }
            $s.Kind = if ($boolish) { 'toggle' } else { 'combo' }
        }
        elseif ($null -ne $s.Max) {
            $s.Kind = 'slider'
        }
        else {
            $s.Kind = 'text'
        }
    }

    $script:SettingsCache = $list

    $script:SettingIndex = @{}
    foreach ($s in $list) { $script:SettingIndex[$s.Id] = $s }

    return $list
}

# ---------- 分类 ----------
$script:CategoryMap = @{
    '238c9fa8-0aad-41ed-83f4-97be242c8f20' = 'sleep'
    '7516b95f-f776-4464-8c53-06167f40cc99' = 'sleep'
    '4f971e89-eebd-4455-a8de-9e59040e7347' = 'buttons'
    '54533251-82be-4824-96c1-47b60b740d00' = 'cpu'
    '0012ee47-9041-4b5d-9b77-535fba8b1442' = 'disk'
    'e73a048d-bf27-4f12-9731-8b2076e8891f' = 'battery'
    '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' = 'net'
    '2a737441-1930-4402-8d77-b2bebba308a3' = 'net'
    '501a4d13-42af-4429-9fd1-a8218c268e20' = 'net'
    '44f3beca-a7c0-460e-9df2-bb8b99e0cba6' = 'gpu'
    '5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c' = 'gpu'
    'd02e4e1e-6b7a-4b3b-9f3e-9e5c4c6b8a11' = 'gpu'
}

function Get-SettingCategory {
    param([Parameter(Mandatory = $true)][string]$SubGuid)
    $key = $SubGuid.ToLower()
    if ($script:CategoryMap.ContainsKey($key)) { return $script:CategoryMap[$key] }
    return 'other'
}

# 常用设置（首页展示的精选列表，顺序即展示顺序）
$script:CommonIds = @(
    '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'  # 睡眠时间
    '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'  # 关闭显示器
    '9d7815a6-7ee4-497e-8888-515a05f02364'  # 休眠时间
    '6738e2c4-e8a5-4a42-b16a-e040e769756e'  # 关闭硬盘
    '893dee8e-2bef-41e0-89c6-b55d0929964c'  # 最小处理器状态
    'bc5038f7-23e0-4960-96da-33abaf5935ec'  # 最大处理器状态
    'aded5e82-b909-4619-9949-f5d71dac0bcb'  # 显示器亮度
    'fbd9aa66-9553-4097-ba44-ed6e9d65eab8'  # 自适应亮度
    'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'  # 唤醒定时器
    '03680956-93bc-4294-bba6-4e0f09bb717f'  # 共享媒体时
    'a7066653-8d6c-40a8-910e-a1f54b84c7e5'  # 开始菜单电源按钮
    '5ca83367-6e45-459f-a27b-476b1d01c936'  # 合上盖子
    '8183ba9a-e910-48da-8769-14ae6dc1170a'  # 低电量水平
    '9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469'  # 关键电量水平
    'd8742dcb-3e6a-4b3c-b3fe-374623cdcf06'  # 低电量操作
    '637ea02f-bbcb-4015-8e2c-a1c7b9c0b546'  # 关键电量操作
)

# ---------- 值显示 ----------
function Format-TimeSeconds {
    param([int]$Seconds)
    if ($Seconds -le 0) { return '从不' }
    if ($Seconds -lt 60) { return "$Seconds 秒" }
    $m = [math]::Floor($Seconds / 60)
    $s = $Seconds % 60
    if ($m -ge 60) {
        $h = [math]::Floor($m / 60)
        $mm = $m % 60
        if ($mm -eq 0) { return "$h 小时" }
        return "$h 小时 $mm 分"
    }
    if ($s -eq 0) { return "$m 分钟" }
    return "$m 分 $s 秒"
}

function Format-SettingValue {
    param($Setting, $Value)

    if ($null -eq $Value) { return '—' }

    if ($Setting.Kind -eq 'toggle' -or $Setting.Kind -eq 'combo') {
        foreach ($o in $Setting.Options) {
            if ($o.Index -eq $Value) { return $o.Name }
        }
        return "索引 $Value"
    }

    if ($Setting.Unit -eq '%') { return "$Value%" }
    if ($Setting.Unit -eq '秒') { return (Format-TimeSeconds -Seconds ([int]$Value)) }
    if ([string]::IsNullOrWhiteSpace($Setting.Unit)) { return "$Value" }
    return "$Value $($Setting.Unit)"
}

function Get-SliderRange {
    param($Setting)

    $max = 100
    if ($Setting.Unit -eq '%') { $max = 100 }
    elseif ($Setting.Unit -eq '秒') { $max = 7200 }
    elseif ($null -ne $Setting.Max -and $Setting.Max -gt 0 -and $Setting.Max -le 100000) { $max = [int]$Setting.Max }
    else { $max = 1000 }

    foreach ($v in @($Setting.AcValue, $Setting.DcValue)) {
        if ($null -ne $v -and $v -gt $max) { $max = [int]$v }
    }

    $tick = 1
    if ($Setting.Unit -eq '秒' -and $max -gt 120) {
        $onTick = $true
        foreach ($v in @($Setting.AcValue, $Setting.DcValue)) {
            if ($null -ne $v -and ($v % 30) -ne 0) { $onTick = $false }
        }
        if ($onTick) { $tick = 30 }
    }

    return [pscustomobject]@{ Min = 0; Max = [double]$max; Tick = [double]$tick }
}

# ---------- 写入 ----------
function Set-PowerValues {
    param([Parameter(Mandatory = $true)][hashtable]$Changes)

    $results = New-Object System.Collections.ArrayList
    foreach ($key in @($Changes.Keys)) {
        $parts = $key -split '\|'
        if ($parts.Count -ne 2) { continue }
        $id = $parts[0]
        $kind = $parts[1]

        $s = $script:SettingIndex[$id]
        if (-not $s) { continue }

        $verb = if ($kind -eq 'ac') { '/setacvalueindex' } else { '/setdcvalueindex' }
        $val = [string]([int]$Changes[$key])

        $res = Invoke-PowerCfg -Arguments @($verb, 'SCHEME_CURRENT', $s.Sub, $id, $val)
        $ok = ($res.Code -eq 0)

        $null = $results.Add([pscustomobject]@{
                Id     = $id
                Kind   = $kind
                Name   = $s.Name
                Value  = $Changes[$key]
                Ok     = $ok
                Output = ($res.Output -join ' ')
            })
    }

    # 让设置立即生效
    $null = Invoke-PowerCfg -Arguments @('/setactive', 'SCHEME_CURRENT')
    $script:SettingsCache = $null

    return $results
}

# ---------- 预设方案 ----------
$script:Presets = @(
    @{
        Key   = 'desk'
        Name  = '常插电 · 工作站'
        Desc  = '关屏 15 分、睡眠 30 分、硬盘不休眠、处理器全速（仅改接通电源）'
        Items = @(
            @{ Id = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Ac = 900; Dc = $null }
            @{ Id = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Ac = 1800; Dc = $null }
            @{ Id = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Ac = 0; Dc = $null }
            @{ Id = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Ac = 5; Dc = $null }
            @{ Id = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Ac = 100; Dc = $null }
            @{ Id = '03680956-93bc-4294-bba6-4e0f09bb717f'; Ac = 0; Dc = $null }
        )
    },
    @{
        Key   = 'nosleep'
        Name  = '长任务 · 不睡眠'
        Desc  = '屏幕与系统都不进入睡眠，适合编译、下载、跑测试（仅改接通电源）'
        Items = @(
            @{ Id = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Ac = 0; Dc = $null }
            @{ Id = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Ac = 0; Dc = $null }
            @{ Id = '9d7815a6-7ee4-497e-8888-515a05f02364'; Ac = 0; Dc = $null }
            @{ Id = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Ac = 0; Dc = $null }
            @{ Id = '03680956-93bc-4294-bba6-4e0f09bb717f'; Ac = 1; Dc = $null }
        )
    },
    @{
        Key   = 'travel'
        Name  = '差旅 · 省电'
        Desc  = '电池下快速关屏、降亮度、提高低电量提醒阈值'
        Items = @(
            @{ Id = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Ac = 300; Dc = 120 }
            @{ Id = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Ac = 900; Dc = 300 }
            @{ Id = 'aded5e82-b909-4619-9949-f5d71dac0bcb'; Ac = 100; Dc = 50 }
            @{ Id = '8183ba9a-e910-48da-8769-14ae6dc1170a'; Ac = 10; Dc = 10 }
            @{ Id = '9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469'; Ac = 5; Dc = 5 }
        )
    },
    @{
        Key   = 'reset'
        Name  = '恢复默认节奏'
        Desc  = '把时间类参数还原为 Windows 平衡方案的出厂取值'
        Items = @(
            @{ Id = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Ac = 600; Dc = 300 }
            @{ Id = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Ac = 1800; Dc = 900 }
            @{ Id = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Ac = 1200; Dc = 600 }
            @{ Id = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Ac = 5; Dc = 5 }
            @{ Id = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Ac = 100; Dc = 100 }
        )
    }
)

function Get-Presets { return $script:Presets }

function Get-PresetChanges {
    param([Parameter(Mandatory = $true)][string]$Key)

    $preset = $script:Presets | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $preset) { return @() }

    $settings = Get-PowerSettings
    $changes = New-Object System.Collections.ArrayList
    foreach ($item in $preset.Items) {
        $s = $settings | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
        if (-not $s) { continue }
        if ($null -ne $item.Ac) {
            if ($s.AcValue -ne $item.Ac) {
                $null = $changes.Add([pscustomobject]@{ Id = $item.Id; Kind = 'ac'; Name = $s.Name; From = $s.AcValue; To = $item.Ac })
            }
        }
        if ($null -ne $item.Dc) {
            if ($s.DcValue -ne $item.Dc) {
                $null = $changes.Add([pscustomobject]@{ Id = $item.Id; Kind = 'dc'; Name = $s.Name; From = $s.DcValue; To = $item.Dc })
            }
        }
    }
    return $changes
}

function Invoke-Preset {
    param([Parameter(Mandatory = $true)][string]$Key)

    $changes = @{}
    foreach ($c in (Get-PresetChanges -Key $Key)) {
        $changes["$($c.Id)|$($c.Kind)"] = $c.To
    }
    if ($changes.Count -eq 0) { return @() }
    return Set-PowerValues -Changes $changes
}

# ---------- 隐藏设置探测 ----------
# 注册表里的名称是间接字符串，形如 @C:\WINDOWS\system32\powrprof.dll,-728,Processor performance boost mode
function Convert-PowerFriendlyName {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $t = $Raw.Trim()
    $m = [regex]::Match($t, '^@[^,]+,-?\d+,(.*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $t
}

function Get-RegistryPowerSettings {
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings'
    $out = New-Object System.Collections.ArrayList

    foreach ($sub in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
        $subKey = Get-Item -Path $sub.PSPath -ErrorAction SilentlyContinue
        $subName = ''
        if ($subKey) { $subName = Convert-PowerFriendlyName ([string]$subKey.GetValue('FriendlyName')) }

        foreach ($set in (Get-ChildItem -Path $sub.PSPath -ErrorAction SilentlyContinue)) {
            $sk = Get-Item -Path $set.PSPath -ErrorAction SilentlyContinue
            if (-not $sk) { continue }
            $raw = [string]$sk.GetValue('FriendlyName')
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $null = $out.Add([pscustomobject]@{
                    Sub        = $sub.PSChildName
                    SubName    = $subName
                    Id         = $set.PSChildName
                    Name       = (Convert-PowerFriendlyName $raw)
                    Attributes = [int]($sk.GetValue('Attributes'))
                })
        }
    }
    return $out
}

# 值得解锁的隐藏设置（按注册表里的英文名匹配，与系统语言无关）
$script:InterestingPatterns = @(
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

function Test-InterestingName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $lower = $Name.ToLowerInvariant()
    foreach ($p in $script:InterestingPatterns) {
        if ($lower.Contains($p)) { return $true }
    }
    return $false
}

function Get-HiddenSettingsInfo {
    $visible = @{}
    try {
        foreach ($s in (Get-PowerSettings)) { $visible["$($s.Sub)|$($s.Id)".ToLower()] = $true }
    }
    catch { }

    $reg = Get-RegistryPowerSettings
    $hidden = New-Object System.Collections.ArrayList
    $interesting = New-Object System.Collections.ArrayList

    foreach ($r in $reg) {
        $key = "$($r.Sub)|$($r.Id)".ToLower()
        if ($visible.ContainsKey($key)) { continue }
        $null = $hidden.Add($r)
        if (Test-InterestingName -Name $r.Name) { $null = $interesting.Add($r) }
    }

    return [pscustomobject]@{
        TotalHidden = $hidden.Count
        Interesting = $interesting
        AllHidden   = $hidden
    }
}

# ---------- 诊断 / 工具 ----------
function Get-BatteryInfo {
    $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $b) {
        return [pscustomobject]@{ HasBattery = $false; Percent = $null; OnAC = $true }
    }
    $status = [int]$b.BatteryStatus
    return [pscustomobject]@{
        HasBattery = $true
        Percent    = [int]$b.EstimatedChargeRemaining
        OnAC       = ($status -ne 1)
    }
}

function Get-SleepCapabilities {
    $res = Invoke-PowerCfg -Arguments @('/a')
    return ($res.Output -join "`n")
}
