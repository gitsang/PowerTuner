param(
    [switch]$SmokeTest,
    [switch]$SelfCheck
)

# ============================================================
#  PowerTuner · Windows 电源策略管理器
#  依赖：Windows 自带 PowerShell 5.1 + WPF，无需安装任何组件
# ============================================================

$ErrorActionPreference = 'Stop'

if ($PSScriptRoot) { $script:Root = $PSScriptRoot }
else { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$script:LogPath = Join-Path $script:Root 'PowerTuner.log'

function Write-Log {
    param([string]$Message)
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    }
    catch { }
}

# ---------- 加载 WPF ----------
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
}
catch {
    $detail = "PowerTuner 启动失败：无法加载 WPF 组件。" + "`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + "这通常意味着系统缺少 .NET Framework 4.x，或该文件被安全软件拦截。"
    Write-Log ("无法加载 WPF：" + $_.Exception.Message)
    try {
        $errFile = Join-Path $script:Root 'PowerTuner-error.txt'
        Set-Content -Path $errFile -Value $detail -Encoding UTF8
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $errFile + '"')
    }
    catch {
        Write-Host $detail
    }
    exit 1
}

. (Join-Path $script:Root 'PowerTuner.Core.ps1')

# ---------- 全局状态 ----------
$script:Win = $null
$script:AllSettings = @()
$script:Category = 'common'
$script:SearchText = ''
$script:Pending = @{}
$script:Syncing = $false
$script:HiddenInfo = $null
$script:SearchTimer = $null
$script:StuckFile = Join-Path $script:Root 'unhide.stuck.txt'
$script:StuckIds = @{}

$script:NavItems = @(
    @{ Key = 'common'; Label = '常用设置' },
    @{ Key = 'sleep'; Label = '睡眠与显示' },
    @{ Key = 'buttons'; Label = '电源按钮与合盖' },
    @{ Key = 'cpu'; Label = '处理器' },
    @{ Key = 'disk'; Label = '磁盘与存储' },
    @{ Key = 'battery'; Label = '电池' },
    @{ Key = 'net'; Label = '网络、USB 与总线' },
    @{ Key = 'gpu'; Label = '显卡' },
    @{ Key = 'other'; Label = '其他策略' },
    @{ Key = 'all'; Label = '全部设置' },
    @{ Key = 'tools'; Label = '工具与备份' }
)

# ============================================================
#  小工具
# ============================================================
function New-Brush {
    param([string]$Hex)
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return New-Object System.Windows.Media.SolidColorBrush($c)
}

function New-Thickness {
    param([double]$L, [double]$T, [double]$R, [double]$B)
    return New-Object System.Windows.Thickness($L, $T, $R, $B)
}

function Get-ThemeStyle {
    param([string]$Key)
    if (-not $script:Win) { return $null }
    return $script:Win.TryFindResource($Key)
}

function Get-CategoryCount {
    param([string]$Key)

    if ($Key -eq 'tools') { return $null }
    if ($Key -eq 'all') { return $script:AllSettings.Count }
    if ($Key -eq 'common') {
        $n = 0
        foreach ($id in $script:CommonIds) { if ($script:SettingIndex.ContainsKey($id)) { $n++ } }
        return $n
    }
    $n = 0
    foreach ($s in $script:AllSettings) {
        if ((Get-SettingCategory $s.Sub) -eq $Key) { $n++ }
    }
    return $n
}

# ============================================================
#  初始化界面
# ============================================================
function Initialize-UI {
    $layoutPath = Join-Path $script:Root 'MainWindow.xaml'
    $themePath = Join-Path $script:Root 'Theme.xaml'

    if (-not (Test-Path -LiteralPath $layoutPath)) { throw "缺少界面文件 MainWindow.xaml" }

    $layoutXaml = Get-Content -LiteralPath $layoutPath -Raw -Encoding UTF8
    $layoutXaml = $layoutXaml -replace '^\s*<\?xml[^>]*\?>\s*', ''
    $script:Win = [System.Windows.Markup.XamlReader]::Parse($layoutXaml)

    if (Test-Path -LiteralPath $themePath) {
        try {
            $themeXaml = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8
            $themeXaml = $themeXaml -replace '^\s*<\?xml[^>]*\?>\s*', ''
            $dict = [System.Windows.Markup.XamlReader]::Parse($themeXaml)
            $script:Win.Resources.MergedDictionaries.Add($dict)
        }
        catch {
            Write-Log ("主题加载失败，改用系统默认外观：" + $_.Exception.Message)
        }
    }

    $script:NavList = $script:Win.FindName('NavList')
    $script:PresetHost = $script:Win.FindName('PresetHost')
    $script:SchemeCombo = $script:Win.FindName('SchemeCombo')
    $script:BtnDup = $script:Win.FindName('BtnDup')
    $script:SearchBox = $script:Win.FindName('SearchBox')
    $script:SearchHint = $script:Win.FindName('SearchHint')
    $script:Banner = $script:Win.FindName('Banner')
    $script:BtnUnhide = $script:Win.FindName('BtnUnhide')
    $script:BannerText = $script:Win.FindName('BannerText')
    $script:BtnRevert = $script:Win.FindName('BtnRevert')
    $script:BtnApply = $script:Win.FindName('BtnApply')
    $script:StatusText = $script:Win.FindName('StatusText')
    $script:MainScroll = $script:Win.FindName('MainScroll')
    $script:SettingsHost = $script:Win.FindName('SettingsHost')

    # 按钮外观（主题缺失时不影响功能）
    $p = Get-ThemeStyle 'BtnPrimary'; if ($p) { $script:BtnApply.Style = $p }
    foreach ($b in @($script:BtnRevert, $script:BtnDup, $script:BtnUnhide)) {
        $g = Get-ThemeStyle 'BtnGhost'
        if ($g) { $b.Style = $g }
    }
}

# ============================================================
#  侧栏 / 方案栏 / 预设
# ============================================================
function Build-Nav {
    $script:Syncing = $true
    $script:NavList.Items.Clear()

    $navStyle = Get-ThemeStyle 'NavItem'
    if ($navStyle) { $script:NavList.ItemContainerStyle = $navStyle }

    foreach ($item in $script:NavItems) {
        $count = Get-CategoryCount $item.Key

        $panel = New-Object System.Windows.Controls.DockPanel

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $item.Label
        $label.FontSize = 12.5
        $label.VerticalAlignment = 'Center'
        $null = $panel.Children.Add($label)

        if ($null -ne $count) {
            $num = New-Object System.Windows.Controls.TextBlock
            $num.Text = [string]$count
            $num.FontSize = 11
            $num.Foreground = New-Brush '#A9AEB6'
            $num.VerticalAlignment = 'Center'
            [System.Windows.Controls.DockPanel]::SetDock($num, [System.Windows.Controls.Dock]::Right)
            $panel.Children.Insert(0, $num)
        }

        $li = New-Object System.Windows.Controls.ListBoxItem
        $li.Content = $panel
        $li.Tag = $item.Key
        $null = $script:NavList.Items.Add($li)
    }

    $script:Syncing = $false
}

function Build-SchemeList {
    $schemes = @(Get-PowerSchemes -Refresh)
    $script:Syncing = $true
    try {
        $script:SchemeCombo.Items.Clear()
        $script:SchemeCombo.DisplayMemberPath = 'Name'
        $activeIdx = 0
        for ($i = 0; $i -lt $schemes.Count; $i++) {
            $null = $script:SchemeCombo.Items.Add($schemes[$i])
            if ($schemes[$i].Active) { $activeIdx = $i }
        }
        $script:SchemeCombo.SelectedIndex = $activeIdx
    }
    finally {
        $script:Syncing = $false
    }
}

function Build-Presets {
    $script:PresetHost.Children.Clear()
    $st = Get-ThemeStyle 'BtnGhost'

    foreach ($p in (Get-Presets)) {
        $btn = New-Object System.Windows.Controls.Button
        if ($st) { $btn.Style = $st }
        $btn.Content = $p.Name
        $btn.Height = 30
        $btn.Margin = New-Thickness 0 0 0 6
        $btn.HorizontalContentAlignment = 'Left'
        $btn.Padding = New-Thickness 12 0 12 0
        $btn.FontSize = 11.5
        $btn.ToolTip = $p.Desc
        $btn.Tag = $p.Key
        $btn.Add_Click({
                param($src, $evt)
                Invoke-UiAction -Label ('快速方案 ' + [string]$src.Tag) -Argument ([string]$src.Tag) -Action { param($k) Show-PresetConfirm -Key $k }
            })
        $null = $script:PresetHost.Children.Add($btn)
    }
}

# ============================================================
#  内容渲染
# ============================================================
function Add-SectionHeader {
    param([string]$Text, [int]$Count, [double]$Top = 12)

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "{0}   ·  {1} 项" -f $Text, $Count
    $tb.FontSize = 11.5
    $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
    $tb.Foreground = New-Brush '#8A9099'
    $tb.Margin = New-Thickness 2 $Top 0 8
    $null = $script:SettingsHost.Children.Add($tb)
}

function Add-EmptyHint {
    param([string]$Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = New-Brush '#9AA0A8'
    $tb.Margin = New-Thickness 4 40 0 0
    $tb.FontSize = 12.5
    $null = $script:SettingsHost.Children.Add($tb)
}

function Test-SettingMatch {
    param($Setting, [string]$Keyword)
    if ([string]::IsNullOrWhiteSpace($Keyword)) { return $true }
    $k = $Keyword.ToLowerInvariant()
    if ($Setting.Name.ToLowerInvariant().Contains($k)) { return $true }
    if ($Setting.Alias -and $Setting.Alias.ToLowerInvariant().Contains($k)) { return $true }
    if ($Setting.SubName -and $Setting.SubName.ToLowerInvariant().Contains($k)) { return $true }
    return $false
}

function Get-FilteredSettings {
    $kw = $script:SearchText
    $cat = $script:Category

    $result = New-Object System.Collections.ArrayList

    if ($cat -eq 'common' -and [string]::IsNullOrWhiteSpace($kw)) {
        foreach ($id in $script:CommonIds) {
            if ($script:SettingIndex.ContainsKey($id)) { $null = $result.Add($script:SettingIndex[$id]) }
        }
        return $result
    }

    foreach ($s in $script:AllSettings) {
        if ([string]::IsNullOrWhiteSpace($kw)) {
            if ($cat -ne 'all' -and (Get-SettingCategory $s.Sub) -ne $cat) { continue }
        }
        if (-not (Test-SettingMatch -Setting $s -Keyword $kw)) { continue }
        $null = $result.Add($s)
    }
    return $result
}

function Add-SettingCardSafe {
    param($Setting)
    try {
        $card = New-SettingCard -Setting $Setting
        $null = $script:SettingsHost.Children.Add($card)
    }
    catch {
        Write-Log ("卡片构建失败 [" + $Setting.Name + "]：" + $_.Exception.Message)
    }
}

function Update-View {
    $script:SettingsHost.Children.Clear()
    $script:Syncing = $true
    try {
        if ($script:Category -eq 'tools') {
            Build-ToolsPage
        }
        else {
            $items = @(Get-FilteredSettings)
            if ($items.Count -eq 0) {
                if ($script:SearchText) { Add-EmptyHint ("没有匹配「" + $script:SearchText + "」的设置") }
                else { Add-EmptyHint '这个分类下暂时没有可调整的策略' }
            }
            elseif ($script:Category -eq 'common' -and [string]::IsNullOrWhiteSpace($script:SearchText)) {
                Add-SectionHeader -Text '常用设置' -Count $items.Count -Top 2
                foreach ($s in $items) { Add-SettingCardSafe -Setting $s }
            }
            else {
                $first = $true
                foreach ($g in ($items | Group-Object -Property Sub)) {
                    $subName = $g.Group[0].SubName
                    if ([string]::IsNullOrWhiteSpace($subName)) { $subName = '未分类' }
                    $top = 14
                    if ($first) { $top = 2 }
                    Add-SectionHeader -Text $subName -Count $g.Count -Top $top
                    $first = $false
                    foreach ($s in $g.Group) { Add-SettingCardSafe -Setting $s }
                }
            }
        }
    }
    finally {
        $script:Syncing = $false
    }
    Update-PendingBar
}

function New-SettingCard {
    param($Setting)

    $card = New-Object System.Windows.Controls.Border
    $cardStyle = Get-ThemeStyle 'Card'
    if ($cardStyle) { $card.Style = $cardStyle }
    else {
        $card.Background = New-Brush '#FFFFFF'
        $card.BorderBrush = New-Brush '#E9EAED'
        $card.BorderThickness = New-Thickness 1 1 1 1
        $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $card.Margin = New-Thickness 0 0 0 8
    }

    $dock = New-Object System.Windows.Controls.DockPanel
    $dock.Margin = New-Thickness 16 11 16 11
    $dock.LastChildFill = $true

    # 先加的通栏更靠右：右列 = 使用电池，其次 = 接通电源，最后填满的是名称
    $cellDc = New-ValueCell -Setting $Setting -Kind 'dc'
    $cellDc.Width = 216
    [System.Windows.Controls.DockPanel]::SetDock($cellDc, [System.Windows.Controls.Dock]::Right)
    $null = $dock.Children.Add($cellDc)

    $cellAc = New-ValueCell -Setting $Setting -Kind 'ac'
    $cellAc.Width = 216
    [System.Windows.Controls.DockPanel]::SetDock($cellAc, [System.Windows.Controls.Dock]::Right)
    $null = $dock.Children.Add($cellAc)

    # 名称 + 来源
    $info = New-Object System.Windows.Controls.StackPanel
    $info.VerticalAlignment = 'Center'
    $info.Margin = New-Thickness 0 0 10 0

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $Setting.Name
    $name.FontSize = 13
    $name.FontWeight = [System.Windows.FontWeights]::SemiBold
    $name.Foreground = New-Brush '#1B1E23'
    $name.TextTrimming = 'CharacterEllipsis'
    $null = $info.Children.Add($name)

    $subParts = @()
    if ($Setting.SubName) { $subParts += $Setting.SubName }
    if ($Setting.Alias) { $subParts += $Setting.Alias }
    if ($subParts.Count -gt 0) {
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = ($subParts -join ' · ')
        $sub.FontSize = 10.5
        $sub.Foreground = New-Brush '#9AA0A8'
        $sub.Margin = New-Thickness 0 3 0 0
        $sub.TextTrimming = 'CharacterEllipsis'
        $null = $info.Children.Add($sub)
    }

    $null = $dock.Children.Add($info)

    $card.Child = $dock
    return $card
}

function New-ValueCell {
    param($Setting, [string]$Kind)

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Thickness 8 0 0 0
    $panel.VerticalAlignment = 'Center'

    $cap = New-Object System.Windows.Controls.TextBlock
    if ($Kind -eq 'ac') { $cap.Text = '接通电源' } else { $cap.Text = '使用电池' }
    $cap.FontSize = 10.5
    $cap.Foreground = New-Brush '#9AA0A8'
    $cap.Margin = New-Thickness 0 0 0 5
    $null = $panel.Children.Add($cap)

    $value = if ($Kind -eq 'ac') { $Setting.AcValue } else { $Setting.DcValue }

    if ($null -eq $value) {
        $na = New-Object System.Windows.Controls.TextBlock
        $na.Text = '不可用'
        $na.FontSize = 11.5
        $na.Foreground = New-Brush '#BFC3CA'
        $null = $panel.Children.Add($na)
        return $panel
    }

    switch ($Setting.Kind) {

        'toggle' {
            $tg = New-Object System.Windows.Controls.Primitives.ToggleButton
            $sw = Get-ThemeStyle 'Switch'
            if ($sw) { $tg.Style = $sw }
            else { $tg.Content = Format-SettingValue $Setting $value }
            $tg.Tag = @{ Id = $Setting.Id; Kind = $Kind; Type = 'toggle' }
            $tg.IsChecked = ($value -ne 0)
            $tg.HorizontalAlignment = 'Left'
            $tg.Add_Click({ param($src, $evt) On-ToggleChanged -Source $src })
            $null = $panel.Children.Add($tg)
        }

        'combo' {
            $cb = New-Object System.Windows.Controls.ComboBox
            $cs = Get-ThemeStyle 'MiniCombo'
            if ($cs) { $cb.Style = $cs }
            $cb.Width = 192
            $cb.HorizontalAlignment = 'Left'
            foreach ($o in $Setting.Options) { $null = $cb.Items.Add($o.Name) }
            $cb.Tag = @{ Id = $Setting.Id; Kind = $Kind; Type = 'combo'; Setting = $Setting }
            $cb.SelectedIndex = (Get-OptionIndex -Setting $Setting -Value $value)
            $cb.Add_SelectionChanged({ param($src, $evt) On-ComboChanged -Source $src })
            $null = $panel.Children.Add($cb)
        }

        'slider' {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'

            $range = Get-SliderRange -Setting $Setting

            $sl = New-Object System.Windows.Controls.Slider
            $ss = Get-ThemeStyle 'SlimSlider'
            if ($ss) { $sl.Style = $ss }
            $sl.Minimum = $range.Min
            $sl.Maximum = $range.Max
            $sl.TickFrequency = $range.Tick
            $sl.IsSnapToTickEnabled = $true
            $sl.Width = 118
            $sl.VerticalAlignment = 'Center'

            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = Format-SettingValue $Setting $value
            $lbl.FontSize = 11.5
            $lbl.Foreground = New-Brush '#3A3F46'
            $lbl.VerticalAlignment = 'Center'
            $lbl.Margin = New-Thickness 10 0 0 0
            $lbl.MinWidth = 66

            $sl.Tag = @{ Id = $Setting.Id; Kind = $Kind; Type = 'slider'; Label = $lbl; Setting = $Setting }
            $sl.Value = [double]$value
            $sl.Add_ValueChanged({ param($src, $evt) On-SliderChanged -Source $src })

            $null = $row.Children.Add($sl)
            $null = $row.Children.Add($lbl)
            $null = $panel.Children.Add($row)
        }

        default {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = Format-SettingValue $Setting $value
            $tb.FontSize = 12
            $tb.Foreground = New-Brush '#3A3F46'
            $null = $panel.Children.Add($tb)
        }
    }

    return $panel
}

function Get-OptionIndex {
    param($Setting, $Value)
    for ($i = 0; $i -lt $Setting.Options.Count; $i++) {
        if ($Setting.Options[$i].Index -eq $Value) { return $i }
    }
    return -1
}

# ============================================================
#  交互
# ============================================================
function Invoke-UiAction {
    param(
        [scriptblock]$Action,
        $Argument = $null,
        [string]$Label = '操作'
    )

    try {
        if ($null -ne $Argument) { & $Action $Argument }
        else { & $Action }
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log ("操作失败 [" + $Label + "]：" + $msg + " | " + $_.ScriptStackTrace)
        try {
            [System.Windows.MessageBox]::Show(
                "「" + $Label + "」执行失败：`n`n" + $msg + "`n`n详细堆栈已写入 PowerTuner.log",
                'PowerTuner', 'OK', 'Error') | Out-Null
        }
        catch { }
    }
}

function On-ToggleChanged {
    param($Source)
    if ($script:Syncing) { return }
    $tag = $Source.Tag
    $v = 0
    if ($Source.IsChecked) { $v = 1 }
    Set-Pending -Id $tag.Id -Kind $tag.Kind -Value $v
}

function On-ComboChanged {
    param($Source)
    if ($script:Syncing) { return }
    $tag = $Source.Tag
    $st = $tag.Setting
    $i = $Source.SelectedIndex
    if ($null -eq $i -or $i -lt 0) { return }
    if ($i -ge $st.Options.Count) { return }
    Set-Pending -Id $tag.Id -Kind $tag.Kind -Value $st.Options[$i].Index
}

function On-SliderChanged {
    param($Source)
    if ($script:Syncing) { return }
    $tag = $Source.Tag
    $v = [int][math]::Round($Source.Value)
    $tag.Label.Text = Format-SettingValue $tag.Setting $v
    Set-Pending -Id $tag.Id -Kind $tag.Kind -Value $v
}

function Set-Pending {
    param([string]$Id, [string]$Kind, [int]$Value)

    $key = "$Id|$Kind"
    $s = $script:SettingIndex[$Id]
    if (-not $s) { return }

    $orig = $null
    if ($Kind -eq 'ac') { $orig = $s.AcValue } else { $orig = $s.DcValue }

    if ($null -ne $orig -and [int]$orig -eq $Value) { $script:Pending.Remove($key) }
    else { $script:Pending[$key] = $Value }

    Update-PendingBar
}

function Update-PendingBar {
    $n = $script:Pending.Count
    if ($n -eq 0) {
        $script:StatusText.Text = '所有显示的值都与系统中当前设置一致'
        $script:BtnApply.IsEnabled = $false
        $script:BtnRevert.IsEnabled = $false
    }
    else {
        $script:StatusText.Text = "有 $n 项更改待应用"
        $script:BtnApply.IsEnabled = $true
        $script:BtnRevert.IsEnabled = $true
    }
}

function Apply-Pending {
    if ($script:Pending.Count -eq 0) { return }

    $count = $script:Pending.Count
    $script:StatusText.Text = '正在写入系统…'
    $script:BtnApply.IsEnabled = $false
    $script:BtnRevert.IsEnabled = $false

    try {
        $res = @(Set-PowerValues -Changes $script:Pending)
    }
    catch {
        Write-Log ("写入失败：" + $_.Exception.Message)
        $script:StatusText.Text = '写入失败：' + $_.Exception.Message
        Update-PendingBar
        return
    }

    $script:Pending = @{}

    $offset = $script:MainScroll.VerticalOffset
    $script:AllSettings = @(Get-PowerSettings -Refresh)
    Update-View
    $script:MainScroll.ScrollToVerticalOffset($offset)

    $fail = @($res | Where-Object { -not $_.Ok })
    if ($fail.Count -gt 0) {
        $detail = ($fail | ForEach-Object { "· " + $_.Name + "：" + $_.Output }) -join "`n"
        [System.Windows.MessageBox]::Show(
            "有 $($fail.Count) 项没能写入（通常是被设备厂商或固件固定住了）：`n`n$detail",
            '应用结果', 'OK', 'Warning') | Out-Null
        $script:StatusText.Text = "已应用 $($res.Count - $fail.Count) 项，$($fail.Count) 项失败"
    }
    else {
        $script:StatusText.Text = "已应用 $count 项更改，立即生效"
    }
}

function Revert-Pending {
    $script:Pending = @{}
    $script:AllSettings = @(Get-PowerSettings -Refresh)
    Update-View
    $script:StatusText.Text = '已放弃未应用的更改'
}

# ============================================================
#  快速方案
# ============================================================
function Show-PresetConfirm {
    param([string]$Key)

    $preset = Get-Presets | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $preset) { return }

    $changes = @(Get-PresetChanges -Key $Key)
    if ($changes.Count -eq 0) {
        [System.Windows.MessageBox]::Show('当前设置已经符合「' + $preset.Name + '」，不需要改动。', '快速方案', 'OK', 'Information') | Out-Null
        return
    }

    $lines = @()
    foreach ($c in $changes) {
        $s = $script:SettingIndex[$c.Id]
        if (-not $s) { continue }
        $side = '接通电源'
        if ($c.Kind -eq 'dc') { $side = '使用电池' }
        $lines += "· " + $s.Name + "（" + $side + "）：" + (Format-SettingValue $s $c.From) + "  →  " + (Format-SettingValue $s $c.To)
    }

    $text = "将应用「" + $preset.Name + "」，共 " + $changes.Count + " 项：`n`n" + ($lines -join "`n") + "`n`n只改动上面列出的项目，其余设置保持不变。"

    $r = [System.Windows.MessageBox]::Show($text, '确认应用方案', 'YesNo', 'Question')
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $script:Pending = @{}
    try { $res = @(Invoke-Preset -Key $Key) }
    catch {
        Write-Log ("方案应用失败：" + $_.Exception.Message)
        $script:StatusText.Text = '方案应用失败：' + $_.Exception.Message
        return
    }

    $script:AllSettings = @(Get-PowerSettings -Refresh)
    Update-View
    Update-Banner

    $fail = @($res | Where-Object { -not $_.Ok })
    if ($fail.Count -gt 0) {
        $script:StatusText.Text = "方案已部分应用，" + $fail.Count + " 项失败"
    }
    else {
        $script:StatusText.Text = "已应用方案「" + $preset.Name + "」"
    }
}

# ============================================================
#  方案切换 / 副本
# ============================================================
function Switch-Scheme {
    param($Scheme)

    if (-not $Scheme) { return }
    if ($Scheme.Active) { return }

    if (-not (Set-ActiveScheme -Guid $Scheme.Guid)) {
        [System.Windows.MessageBox]::Show('切换电源方案失败。', 'PowerTuner', 'OK', 'Warning') | Out-Null
        return
    }

    $script:Pending = @{}
    $script:AllSettings = @(Get-PowerSettings -Refresh)
    Build-SchemeList
    Update-View
    $script:StatusText.Text = '已切换到方案「' + $Scheme.Name + '」'
}

function New-SchemeCopy {
    $r = [System.Windows.MessageBox]::Show(
        "将基于当前方案创建一个副本，并立即切换到副本。`n`n副本只复制设置值，不会影响原方案。",
        '新建方案副本', 'YesNo', 'Question')
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $res = Invoke-PowerCfg -Arguments @('/duplicatescheme', 'SCHEME_CURRENT')
    $joined = ($res.Output -join ' ')
    $m = [regex]::Match($joined, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if (-not $m.Success) {
        [System.Windows.MessageBox]::Show("创建副本失败。`n`n" + $joined, 'PowerTuner', 'OK', 'Warning') | Out-Null
        return
    }

    $guid = $m.Groups[1].Value
    $name = 'PowerTuner 自定义'
    $null = Invoke-PowerCfg -Arguments @('/changename', $guid, $name)
    $null = Invoke-PowerCfg -Arguments @('/setactive', $guid)

    $script:Pending = @{}
    $script:AllSettings = @(Get-PowerSettings -Refresh)
    Build-SchemeList
    Update-View
    $script:StatusText.Text = '已创建并切换到「' + $name + '」'
}

# ============================================================
#  隐藏项
# ============================================================
function Load-StuckIds {
    $script:StuckIds = @{}
    if (Test-Path -LiteralPath $script:StuckFile) {
        try {
            foreach ($line in (Get-Content -LiteralPath $script:StuckFile -Encoding UTF8)) {
                $t = ([string]$line).Trim()
                if ($t) { $script:StuckIds[$t.ToLower()] = $true }
            }
        }
        catch { }
    }
}

function Save-StuckIds {
    try {
        Set-Content -LiteralPath $script:StuckFile -Value (@($script:StuckIds.Keys) -join "`r`n") -Encoding UTF8
    }
    catch { }
}

function Get-PendingHidden {
    param($Info)
    $list = @()
    if (-not $Info) { return $list }
    foreach ($it in $Info.Interesting) {
        $k = ("$($it.Sub)|$($it.Id)").ToLower()
        if (-not $script:StuckIds.ContainsKey($k)) { $list += $it }
    }
    return $list
}

function Update-Banner {
    if ($null -eq $script:HiddenInfo) {
        try { $script:HiddenInfo = Get-HiddenSettingsInfo }
        catch {
            Write-Log ("隐藏项探测失败：" + $_.Exception.Message)
            $script:Banner.Visibility = 'Collapsed'
            return
        }
    }

    $h = $script:HiddenInfo
    $pending = @(Get-PendingHidden -Info $h)

    if ($pending.Count -gt 0) {
        $script:Banner.Visibility = 'Visible'
        $script:BannerText.Text = "系统里还有 $($h.TotalHidden) 项策略被 Windows 默认隐藏，其中 $($pending.Count) 项是性能、散热、待机相关的关键调优项（如性能提升模式、核心停放、散热策略）。解锁后即可在本工具中调整。"
        $script:BtnUnhide.IsEnabled = $true
        $script:BtnUnhide.Content = "解锁 $($pending.Count) 项"
    }
    else {
        $script:Banner.Visibility = 'Collapsed'
        $script:BtnUnhide.IsEnabled = $false
    }
}

function Select-NavByKey {
    param([string]$Key)
    $script:Syncing = $true
    try {
        for ($i = 0; $i -lt $script:NavList.Items.Count; $i++) {
            if ([string]$script:NavList.Items[$i].Tag -eq $Key) {
                $script:NavList.SelectedIndex = $i
                return
            }
        }
    }
    finally {
        $script:Syncing = $false
    }
}

function Invoke-Unhide {
    $pending = @(Get-PendingHidden -Info $script:HiddenInfo)
    if ($pending.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "没有需要解锁的项目了。`n`n仍被 Windows 隐藏的策略由固件或驱动固定，软件无法改变它们的可见性。",
            '解锁隐藏设置', 'OK', 'Information') | Out-Null
        return
    }

    $script:BtnUnhide.IsEnabled = $false
    $script:StatusText.Text = '正在请求管理员权限…'

    $script:UnhideScript = Join-Path $script:Root 'Unhide-PowerSettings.ps1'
    if (-not (Test-Path -LiteralPath $script:UnhideScript)) {
        [System.Windows.MessageBox]::Show('缺少 Unhide-PowerSettings.ps1，无法解锁。', 'PowerTuner', 'OK', 'Warning') | Out-Null
        $script:BtnUnhide.IsEnabled = $true
        return
    }

    $resultFile = Join-Path $script:Root 'unhide.result.txt'
    if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"' + $script:UnhideScript + '"')
        )
    }
    catch {
        $script:StatusText.Text = '已取消管理员授权'
        $script:BtnUnhide.IsEnabled = $true
        return
    }

    $msg = '已完成'
    if (Test-Path -LiteralPath $resultFile) {
        $msg = (Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8).Trim()
    }

    # 重新探测：这一轮尝试过仍然隐藏的，就是固件/驱动锁定的，记下来不再反复提示
    $script:AllSettings = @(Get-PowerSettings -Refresh)
    $script:HiddenInfo = $null
    try { $script:HiddenInfo = Get-HiddenSettingsInfo } catch { }

    $stuckCount = 0
    if ($script:HiddenInfo) {
        $stuckCount = $script:HiddenInfo.Interesting.Count
        foreach ($it in $script:HiddenInfo.Interesting) {
            $k = ("$($it.Sub)|$($it.Id)").ToLower()
            $script:StuckIds[$k] = $true
        }
        Save-StuckIds
    }

    Build-Nav
    Select-NavByKey -Key $script:Category
    Update-Banner
    Update-View

    if ($stuckCount -gt 0) {
        $script:StatusText.Text = "解锁完成：$msg；另有 $stuckCount 项由固件或驱动固定，无法通过软件显示"
    }
    else {
        $script:StatusText.Text = '解锁完成：' + $msg
    }
}

# ============================================================
#  工具页
# ============================================================
function New-ToolCard {
    param([string]$Title, [string]$Desc, $Buttons)

    $card = New-Object System.Windows.Controls.Border
    $cs = Get-ThemeStyle 'Card'
    if ($cs) { $card.Style = $cs }
    else {
        $card.Background = New-Brush '#FFFFFF'
        $card.BorderBrush = New-Brush '#E9EAED'
        $card.BorderThickness = New-Thickness 1 1 1 1
        $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $card.Margin = New-Thickness 0 0 0 8
    }

    $dock = New-Object System.Windows.Controls.DockPanel
    $dock.Margin = New-Thickness 16 14 16 14
    $dock.LastChildFill = $true

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($bar, [System.Windows.Controls.Dock]::Right)
    $gs = Get-ThemeStyle 'BtnGhost'

    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        if ($gs) { $btn.Style = $gs }
        $btn.Content = $b.Text
        $btn.Height = 30
        $btn.Padding = New-Thickness 14 0 14 0
        $btn.Margin = New-Thickness 8 0 0 0
        $btn.Tag = $b.Action
        $btn.Add_Click({
                param($src, $evt)
                if ($src.Tag) { Invoke-UiAction -Label ([string]$src.Content) -Action $src.Tag }
            })
        $null = $bar.Children.Add($btn)
    }

    $null = $dock.Children.Add($bar)

    $info = New-Object System.Windows.Controls.StackPanel
    $info.VerticalAlignment = 'Center'

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title
    $t.FontSize = 13
    $t.FontWeight = [System.Windows.FontWeights]::SemiBold
    $t.Foreground = New-Brush '#1B1E23'
    $null = $info.Children.Add($t)

    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $Desc
    $d.FontSize = 11.5
    $d.Foreground = New-Brush '#8A9099'
    $d.Margin = New-Thickness 0 4 12 0
    $d.TextWrapping = 'Wrap'
    $null = $info.Children.Add($d)

    $null = $dock.Children.Add($info)

    $card.Child = $dock
    return $card
}

function Build-ToolsPage {
    $h = $script:HiddenInfo
    $hiddenTotal = 0
    $hiddenGood = 0
    if ($h) {
        $hiddenTotal = $h.TotalHidden
        $hiddenGood = $h.Interesting.Count
    }

    Add-SectionHeader -Text '备份与迁移' -Count 2 -Top 2

    $card = New-ToolCard -Title '导出当前方案备份' `
        -Desc '把当前电源方案的全部设置导出为 .pow 文件。重装系统、换机或改坏了都可一键还原。' `
        -Buttons @(@{ Text = '导出…'; Action = { Export-SchemeBackup } })
    $null = $script:SettingsHost.Children.Add($card)

    $card = New-ToolCard -Title '导入方案备份' `
        -Desc '从 .pow 文件还原方案。导入后会作为新方案出现在顶部列表，不会覆盖现有方案。' `
        -Buttons @(@{ Text = '导入…'; Action = { Import-SchemeBackup } })
    $null = $script:SettingsHost.Children.Add($card)

    Add-SectionHeader -Text '诊断报告' -Count 2 -Top 14

    $card = New-ToolCard -Title '电池健康报告' `
        -Desc '生成完整电池报告（设计容量、实际容量、循环次数、最近三天耗电曲线），生成后用浏览器打开。' `
        -Buttons @(@{ Text = '生成报告'; Action = { Show-BatteryReport } })
    $null = $script:SettingsHost.Children.Add($card)

    $card = New-ToolCard -Title '能源效率诊断' `
        -Desc '监视 60 秒内的电源效率问题（哪些程序阻止睡眠、哪些设备不让 CPU 降频）。需要管理员权限。' `
        -Buttons @(@{ Text = '生成报告'; Action = { Show-EnergyReport } })
    $null = $script:SettingsHost.Children.Add($card)

    Add-SectionHeader -Text '隐藏策略' -Count 1 -Top 14

    $desc = "Windows 把 $hiddenTotal 项电源策略从界面隐藏了，其中 $hiddenGood 项是性能、散热、待机相关的关键项。解锁只调整可见性，不改变任何数值。"
    $card = New-ToolCard -Title '解锁隐藏设置' -Desc $desc `
        -Buttons @(@{ Text = '解锁…'; Action = { Invoke-Unhide } })
    $null = $script:SettingsHost.Children.Add($card)

    Add-SectionHeader -Text '系统面板' -Count 1 -Top 14

    $card = New-ToolCard -Title '打开系统自带电源设置' `
        -Desc '跳到 Windows 设置里的电源页面，或经典的「电源选项」控制面板。' `
        -Buttons @(
        @{ Text = '系统设置'; Action = { Start-Process 'ms-settings:power' } },
        @{ Text = '经典面板'; Action = { Start-Process 'powercfg.cpl' } }
    )
    $null = $script:SettingsHost.Children.Add($card)
}

# ============================================================
#  工具动作
# ============================================================
function Export-SchemeBackup {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = '导出电源方案'
    $dlg.Filter = '电源方案备份 (*.pow)|*.pow'
    $dlg.FileName = 'PowerTuner-方案备份-' + (Get-Date -Format 'yyyyMMdd') + '.pow'
    if ($dlg.ShowDialog() -ne $true) { return }

    $path = $dlg.FileName
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }

    $res = Invoke-PowerCfg -Arguments @('/export', $path, 'SCHEME_CURRENT')
    if ($res.Code -eq 0 -and (Test-Path -LiteralPath $path)) {
        $script:StatusText.Text = '已导出到 ' + $path
    }
    else {
        [System.Windows.MessageBox]::Show("导出失败：`n`n" + ($res.Output -join "`n"), 'PowerTuner', 'OK', 'Warning') | Out-Null
    }
}

function Import-SchemeBackup {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = '导入电源方案'
    $dlg.Filter = '电源方案备份 (*.pow)|*.pow|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -ne $true) { return }

    $res = Invoke-PowerCfg -Arguments @('/import', $dlg.FileName)
    if ($res.Code -ne 0) {
        [System.Windows.MessageBox]::Show("导入失败：`n`n" + ($res.Output -join "`n"), 'PowerTuner', 'OK', 'Warning') | Out-Null
        return
    }

    Get-PowerSchemes -Refresh | Out-Null
    Build-SchemeList
    $script:StatusText.Text = '已导入方案，可在顶部下拉框中切换'
}

function Show-BatteryReport {
    $path = Join-Path $env:TEMP ('PowerTuner-电池报告-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.html')
    $res = Invoke-PowerCfg -Arguments @('/batteryreport', '/output', $path)
    if ($res.Code -eq 0 -and (Test-Path -LiteralPath $path)) {
        Start-Process $path
        $script:StatusText.Text = '电池报告已生成：' + $path
    }
    else {
        [System.Windows.MessageBox]::Show("生成电池报告失败：`n`n" + ($res.Output -join "`n"), 'PowerTuner', 'OK', 'Warning') | Out-Null
    }
}

function Show-EnergyReport {
    $path = Join-Path $env:TEMP ('PowerTuner-能源报告-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.html')
    $script:StatusText.Text = '正在采集 60 秒能源数据（需要管理员权限），请保持电脑空闲…'

    try {
        $proc = Start-Process -FilePath 'powercfg.exe' -Verb RunAs -PassThru -Wait -ArgumentList @(
            '/energy', '/output', $path, '/duration', '60'
        )
    }
    catch {
        $script:StatusText.Text = '已取消管理员授权'
        return
    }

    if (Test-Path -LiteralPath $path) {
        Start-Process $path
        $script:StatusText.Text = '能源报告已生成：' + $path
    }
    else {
        $script:StatusText.Text = '能源报告生成失败（可能被取消或耗时不足）'
    }
}

# ============================================================
#  启动
# ============================================================
function Start-App {
    Initialize-UI

    $battery = Get-BatteryInfo
    $subtitle = 'Windows 电源策略管理器'
    if ($battery.HasBattery) {
        $subtitle = "笔记本 · 电量 $($battery.Percent)%"
        if ($battery.OnAC) { $subtitle += ' · 已接电源' }
        else { $subtitle += ' · 使用电池' }
    }
    $script:Win.Title = 'PowerTuner · 电源策略管理器 — ' + $subtitle

    $script:AllSettings = @(Get-PowerSettings -Refresh)

    Build-SchemeList
    Build-Nav
    Build-Presets
    Load-StuckIds
    Update-Banner

    # ---------- 自检模式：构造全部卡片，把失败项一次性写进日志 ----------
    if ($SelfCheck) {
        $okCount = 0
        $failCount = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()

        foreach ($s in $script:AllSettings) {
            try {
                $null = New-SettingCard -Setting $s
                $okCount++
            }
            catch {
                $failCount++
                Write-Log ("自检失败 [卡片] " + $s.SubName + " / " + $s.Name + "：" + $_.Exception.Message)
            }
        }

        try { Build-ToolsPage }
        catch {
            $failCount++
            Write-Log ("自检失败 [工具页]：" + $_.Exception.Message)
        }

        foreach ($cat in @('sleep', 'buttons', 'cpu', 'disk', 'battery', 'net', 'gpu', 'other', 'all', 'common', 'tools')) {
            try {
                $script:Category = $cat
                $script:SearchText = ''
                Update-View
            }
            catch {
                $failCount++
                Write-Log ("自检失败 [视图 " + $cat + "]：" + $_.Exception.Message)
            }
        }

        $elapsed = [math]::Round($sw.Elapsed.TotalMilliseconds)
        $line = "自检完成：设置总数 $($script:AllSettings.Count)，卡片成功 $okCount，失败 $failCount，视图切换通过，耗时 $elapsed ms"
        Write-Log $line
        Write-Output $line
        return
    }

    # 事件绑定
    $script:NavList.Add_SelectionChanged({
            param($src, $evt)
            if ($script:Syncing) { return }
            $item = $script:NavList.SelectedItem
            if (-not $item) { return }
            $script:Category = [string]$item.Tag
            Invoke-UiAction -Label '切换分类' -Action {
                $script:MainScroll.ScrollToTop()
                Update-View
            }
        })

    $script:SchemeCombo.Add_SelectionChanged({
            param($src, $evt)
            if ($script:Syncing) { return }
            $picked = $script:SchemeCombo.SelectedItem
            Invoke-UiAction -Label '切换电源方案' -Argument $picked -Action { param($s) Switch-Scheme -Scheme $s }
        })

    $script:BtnDup.Add_Click({ param($src, $evt) Invoke-UiAction -Label '新建方案副本' -Action { New-SchemeCopy } })
    $script:BtnApply.Add_Click({ param($src, $evt) Invoke-UiAction -Label '应用更改' -Action { Apply-Pending } })
    $script:BtnRevert.Add_Click({ param($src, $evt) Invoke-UiAction -Label '撤销更改' -Action { Revert-Pending } })
    $script:BtnUnhide.Add_Click({ param($src, $evt) Invoke-UiAction -Label '解锁隐藏设置' -Action { Invoke-Unhide } })

    $script:SearchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(260)
    $script:SearchTimer.Add_Tick({
            $script:SearchTimer.Stop()
            Invoke-UiAction -Label '搜索' -Action { Update-View }
        })

    $script:SearchBox.Add_TextChanged({
        param($src, $evt)
        $script:SearchText = $script:SearchBox.Text.Trim()
        if ($script:SearchText) { $script:SearchHint.Visibility = 'Collapsed' }
        else { $script:SearchHint.Visibility = 'Visible' }
        $script:SearchTimer.Stop()
        $script:SearchTimer.Start()
    })

    Update-PendingBar

    # 默认选中「常用设置」
    if ($script:NavList.Items.Count -gt 0) {
        $script:Category = 'common'
        Select-NavByKey -Key 'common'
        Update-View
    }

    if ($SmokeTest) {
        Write-Log '自检模式：界面构建成功'
        Write-Output 'SMOKE-OK'
        $script:Win.Close()
        return
    }

    $null = $script:Win.ShowDialog()
}

try {
    Start-App
}
catch {
    $msg = $_.Exception.Message
    $stack = $_.ScriptStackTrace
    Write-Log ("致命错误：" + $msg + " | " + $stack)
    try {
        [System.Windows.MessageBox]::Show(
            "PowerTuner 启动失败：`n`n$msg`n`n详细信息已写入：`n$script:LogPath",
            'PowerTuner', 'OK', 'Error') | Out-Null
    }
    catch { }
    exit 1
}
