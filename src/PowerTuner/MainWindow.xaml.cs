using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using PowerTuner.Models;
using PowerTuner.Services;

namespace PowerTuner
{
    public partial class MainWindow : Window
    {
        private readonly PowerCfgService _svc = new PowerCfgService();
        private readonly Dictionary<string, PowerSetting> _index = new Dictionary<string, PowerSetting>();
        private readonly Dictionary<string, int> _pending = new Dictionary<string, int>();

        private List<PowerSetting> _all = new List<PowerSetting>();
        private string _category = "common";
        private bool _suppress;
        private DispatcherTimer _searchTimer;
        private HiddenScan _hidden;
        private HashSet<string> _stuck = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // ---------- 常量表 ----------
        private static readonly string[] CommonIds = new string[]
        {
            "29f6c1db-86da-48c5-9fdb-f2b67b1f44da",
            "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e",
            "9d7815a6-7ee4-497e-8888-515a05f02364",
            "6738e2c4-e8a5-4a42-b16a-e040e769756e",
            "893dee8e-2bef-41e0-89c6-b55d0929964c",
            "bc5038f7-23e0-4960-96da-33abaf5935ec",
            "aded5e82-b909-4619-9949-f5d71dac0bcb",
            "fbd9aa66-9553-4097-ba44-ed6e9d65eab8",
            "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d",
            "03680956-93bc-4294-bba6-4e0f09bb717f",
            "a7066653-8d6c-40a8-910e-a1f54b84c7e5",
            "5ca83367-6e45-459f-a27b-476b1d01c936",
            "8183ba9a-e910-48da-8769-14ae6dc1170a",
            "9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469",
            "d8742dcb-3e6a-4b3c-b3fe-374623cdcf06",
            "637ea02f-bbcb-4015-8e2c-a1c7b9c0b546"
        };

        private static readonly Dictionary<string, string> CategoryOfSub = new Dictionary<string, string>
        {
            { "238c9fa8-0aad-41ed-83f4-97be242c8f20", "sleep" },
            { "7516b95f-f776-4464-8c53-06167f40cc99", "sleep" },
            { "4f971e89-eebd-4455-a8de-9e59040e7347", "buttons" },
            { "54533251-82be-4824-96c1-47b60b740d00", "cpu" },
            { "0012ee47-9041-4b5d-9b77-535fba8b1442", "disk" },
            { "e73a048d-bf27-4f12-9731-8b2076e8891f", "battery" },
            { "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1", "net" },
            { "2a737441-1930-4402-8d77-b2bebba308a3", "net" },
            { "501a4d13-42af-4429-9fd1-a8218c268e20", "net" },
            { "44f3beca-a7c0-460e-9df2-bb8b99e0cba6", "gpu" },
            { "5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c", "gpu" }
        };

        private static readonly string[] NavKeys = new string[]
        {
            "common", "sleep", "buttons", "cpu", "disk", "battery", "net", "gpu", "other", "all", "tools"
        };

        private static readonly string[] NavLabels = new string[]
        {
            "常用设置", "睡眠与显示", "电源按钮与合盖", "处理器", "磁盘与存储",
            "电池", "网络、USB 与总线", "显卡", "其他策略", "全部设置", "工具与备份"
        };

        private sealed class CellTag
        {
            public PowerSetting Setting { get; set; }
            public string Side { get; set; }
            public TextBlock Label { get; set; }
        }

        public MainWindow()
        {
            InitializeComponent();
            Loaded += OnLoaded;
        }

        // ============================================================
        //  启动
        // ============================================================
        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            try
            {
                _stuck = HiddenSettings.LoadStuck();

                SchemeCombo.SelectionChanged += OnSchemeChanged;
                BtnDup.Click += OnDuplicateScheme;
                BtnApply.Click += OnApply;
                BtnRevert.Click += OnRevert;
                BtnUnhide.Click += OnUnhide;

                _searchTimer = new DispatcherTimer();
                _searchTimer.Interval = TimeSpan.FromMilliseconds(250);
                _searchTimer.Tick += OnSearchTick;

                LoadSchemes();
                LoadSettings();
                BuildNav();
                BuildPresets();
                RefreshHidden();

                if (NavList.Items.Count > 0) { NavList.SelectedIndex = 0; }
                RenderSettings();
                UpdatePendingBar();
            }
            catch (Exception ex)
            {
                StatusText.Text = "启动失败：" + ex.Message;
                MessageBox.Show(ex.ToString(), "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void LoadSettings()
        {
            _all = _svc.GetSettings();
            _index.Clear();
            foreach (PowerSetting s in _all) { _index[s.Id] = s; }
        }

        private void LoadSchemes()
        {
            List<PowerScheme> schemes = _svc.GetSchemes();
            _suppress = true;
            try
            {
                SchemeCombo.Items.Clear();
                SchemeCombo.DisplayMemberPath = "Name";

                int activeIndex = 0;
                for (int i = 0; i < schemes.Count; i++)
                {
                    SchemeCombo.Items.Add(schemes[i]);
                    if (schemes[i].Active) { activeIndex = i; }
                }
                if (schemes.Count > 0) { SchemeCombo.SelectedIndex = activeIndex; }
            }
            finally { _suppress = false; }
        }

        // ============================================================
        //  侧栏 / 预设按钮
        // ============================================================
        private void BuildNav()
        {
            _suppress = true;
            try
            {
                NavList.Items.Clear();
                for (int i = 0; i < NavKeys.Length; i++)
                {
                    DockPanel panel = new DockPanel();

                    int count = CountForCategory(NavKeys[i]);
                    if (count >= 0)
                    {
                        TextBlock number = new TextBlock();
                        number.Text = count.ToString();
                        number.FontSize = 11;
                        number.Foreground = new SolidColorBrush(Color.FromRgb(0xA9, 0xAE, 0xB6));
                        number.VerticalAlignment = VerticalAlignment.Center;
                        DockPanel.SetDock(number, Dock.Right);
                        panel.Children.Add(number);
                    }

                    TextBlock label = new TextBlock();
                    label.Text = NavLabels[i];
                    label.FontSize = 12.5;
                    label.VerticalAlignment = VerticalAlignment.Center;
                    panel.Children.Add(label);

                    ListBoxItem item = new ListBoxItem();
                    item.Content = panel;
                    item.Tag = NavKeys[i];
                    NavList.Items.Add(item);
                }
            }
            finally { _suppress = false; }
        }

        /// <summary>返回该分类的项目数；工具页返回 -1（不显示数字）。</summary>
        private int CountForCategory(string key)
        {
            if (key == "tools") { return -1; }
            if (key == "all") { return _all.Count; }

            if (key == "common")
            {
                int n = 0;
                foreach (string id in CommonIds) { if (_index.ContainsKey(id)) { n++; } }
                return n;
            }

            int count = 0;
            foreach (PowerSetting s in _all)
            {
                if (CategoryFor(s.Sub) == key) { count++; }
            }
            return count;
        }

        private static string CategoryFor(string subGuid)
        {
            string key;
            if (subGuid != null && CategoryOfSub.TryGetValue(subGuid.ToLowerInvariant(), out key)) { return key; }
            return "other";
        }

        private void BuildPresets()
        {
            PresetHost.Children.Clear();
            Style ghost = TryFindResource("BtnGhost") as Style;

            foreach (Preset preset in Presets.All())
            {
                Button button = new Button();
                if (ghost != null) { button.Style = ghost; }
                button.Content = preset.Name;
                button.Height = 30;
                button.Margin = new Thickness(0, 0, 0, 6);
                button.Padding = new Thickness(12, 0, 12, 0);
                button.HorizontalContentAlignment = HorizontalAlignment.Left;
                button.FontSize = 11.5;
                button.ToolTip = preset.Description;
                button.Tag = preset.Key;
                button.Click += OnPresetClick;

                PresetHost.Children.Add(button);
            }
        }

        // ============================================================
        //  渲染
        // ============================================================
        private List<PowerSetting> Filtered()
        {
            string keyword = (SearchBox.Text ?? string.Empty).Trim();
            List<PowerSetting> result = new List<PowerSetting>();

            if (_category == "common" && keyword.Length == 0)
            {
                foreach (string id in CommonIds)
                {
                    PowerSetting setting;
                    if (_index.TryGetValue(id, out setting)) { result.Add(setting); }
                }
                return result;
            }

            foreach (PowerSetting setting in _all)
            {
                if (keyword.Length == 0)
                {
                    if (_category != "all" && CategoryFor(setting.Sub) != _category) { continue; }
                }
                else if (!Matches(setting, keyword)) { continue; }

                result.Add(setting);
            }
            return result;
        }

        private static bool Matches(PowerSetting setting, string keyword)
        {
            string k = keyword.ToLowerInvariant();
            if (setting.Name != null && setting.Name.ToLowerInvariant().Contains(k)) { return true; }
            if (!string.IsNullOrEmpty(setting.Alias) && setting.Alias.ToLowerInvariant().Contains(k)) { return true; }
            if (!string.IsNullOrEmpty(setting.SubName) && setting.SubName.ToLowerInvariant().Contains(k)) { return true; }
            return false;
        }

        private void RenderSettings()
        {
            SettingsHost.Children.Clear();

            if (_category == "tools")
            {
                BuildToolsPage();
                UpdatePendingBar();
                return;
            }

            List<PowerSetting> items = Filtered();
            if (items.Count == 0)
            {
                AddHint(string.IsNullOrEmpty((SearchBox.Text ?? "").Trim())
                    ? "这个分类下暂时没有可调整的策略"
                    : "没有匹配「" + SearchBox.Text.Trim() + "」的策略");
                UpdatePendingBar();
                return;
            }

            _suppress = true;
            try
            {
                string lastSub = null;
                foreach (PowerSetting setting in items)
                {
                    string subName = string.IsNullOrEmpty(setting.SubName) ? "未分类" : setting.SubName;

                    if (subName != lastSub)
                    {
                        AddHeader(subName, CountInSub(items, setting.Sub));
                        lastSub = subName;
                    }

                    SettingsHost.Children.Add(BuildCard(setting));
                }
            }
            finally { _suppress = false; }

            UpdatePendingBar();
        }

        private void AddHeader(string text, int count)
        {
            TextBlock header = new TextBlock();
            header.Text = text + "   ·   " + count + " 项";
            header.FontSize = 11.5;
            header.FontWeight = FontWeights.SemiBold;
            header.Foreground = new SolidColorBrush(Color.FromRgb(0x8A, 0x90, 0x99));
            header.Margin = new Thickness(2, 14, 0, 8);
            SettingsHost.Children.Add(header);
        }

        private void AddHint(string text)
        {
            TextBlock hint = new TextBlock();
            hint.Text = text;
            hint.FontSize = 12.5;
            hint.Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0xA0, 0xA8));
            hint.Margin = new Thickness(4, 40, 0, 0);
            SettingsHost.Children.Add(hint);
        }

        private static int CountInSub(List<PowerSetting> items, string sub)
        {
            int n = 0;
            foreach (PowerSetting s in items) { if (s.Sub == sub) { n++; } }
            return n;
        }

        private Border BuildCard(PowerSetting setting)
        {
            Border card = new Border();
            card.Style = (Style)FindResource("Card");

            DockPanel dock = new DockPanel();
            dock.Margin = new Thickness(16, 11, 16, 11);
            dock.LastChildFill = true;

            StackPanel dcCell = BuildValueCell(setting, "dc");
            dcCell.Width = 216;
            DockPanel.SetDock(dcCell, Dock.Right);
            dock.Children.Add(dcCell);

            StackPanel acCell = BuildValueCell(setting, "ac");
            acCell.Width = 216;
            DockPanel.SetDock(acCell, Dock.Right);
            dock.Children.Add(acCell);

            StackPanel info = new StackPanel();
            info.VerticalAlignment = VerticalAlignment.Center;
            info.Margin = new Thickness(0, 0, 10, 0);

            TextBlock name = new TextBlock();
            name.Text = setting.Name;
            name.FontSize = 13;
            name.FontWeight = FontWeights.SemiBold;
            name.Foreground = new SolidColorBrush(Color.FromRgb(0x1B, 0x1E, 0x23));
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            info.Children.Add(name);

            if (!string.IsNullOrEmpty(setting.SubName) || !string.IsNullOrEmpty(setting.Alias))
            {
                TextBlock sub = new TextBlock();
                sub.Text = setting.SubName +
                    (string.IsNullOrEmpty(setting.Alias) ? "" : " · " + setting.Alias);
                sub.FontSize = 10.5;
                sub.Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0xA0, 0xA8));
                sub.Margin = new Thickness(0, 3, 0, 0);
                sub.TextTrimming = TextTrimming.CharacterEllipsis;
                info.Children.Add(sub);
            }

            dock.Children.Add(info);
            card.Child = dock;
            return card;
        }

        private StackPanel BuildValueCell(PowerSetting setting, string side)
        {
            StackPanel panel = new StackPanel();
            panel.Margin = new Thickness(8, 0, 0, 0);
            panel.VerticalAlignment = VerticalAlignment.Center;

            TextBlock caption = new TextBlock();
            caption.Text = side == "ac" ? "接通电源" : "使用电池";
            caption.FontSize = 10.5;
            caption.Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0xA0, 0xA8));
            caption.Margin = new Thickness(0, 0, 0, 5);
            panel.Children.Add(caption);

            int? value = side == "ac" ? setting.Ac : setting.Dc;

            if (!value.HasValue)
            {
                TextBlock na = new TextBlock();
                na.Text = "不可用";
                na.FontSize = 11.5;
                na.Foreground = new SolidColorBrush(Color.FromRgb(0xBF, 0xC3, 0xCA));
                panel.Children.Add(na);
                return panel;
            }

            CellTag tag = new CellTag { Setting = setting, Side = side };

            switch (setting.Kind)
            {
                case SettingKind.Toggle:
                    {
                        ToggleButton toggle = new ToggleButton();
                        Style switchStyle = TryFindResource("Switch") as Style;
                        if (switchStyle != null) { toggle.Style = switchStyle; }
                        else { toggle.Content = PowerCfgService.FormatValue(setting, value); }
                        toggle.HorizontalAlignment = HorizontalAlignment.Left;
                        toggle.IsChecked = value.Value != 0;
                        toggle.Tag = tag;
                        toggle.Click += OnToggleChanged;
                        panel.Children.Add(toggle);
                        break;
                    }

                case SettingKind.Combo:
                    {
                        ComboBox combo = new ComboBox();
                        Style comboStyle = TryFindResource("MiniCombo") as Style;
                        if (comboStyle != null) { combo.Style = comboStyle; }
                        combo.Width = 192;
                        combo.HorizontalAlignment = HorizontalAlignment.Left;

                        int selected = -1;
                        for (int i = 0; i < setting.Options.Count; i++)
                        {
                            combo.Items.Add(setting.Options[i].Name);
                            if (setting.Options[i].Index == value.Value) { selected = i; }
                        }
                        combo.SelectedIndex = selected;
                        combo.Tag = tag;
                        combo.SelectionChanged += OnComboChanged;
                        panel.Children.Add(combo);
                        break;
                    }

                case SettingKind.Slider:
                    {
                        StackPanel row = new StackPanel();
                        row.Orientation = Orientation.Horizontal;

                        PowerCfgService.SliderRange range = PowerCfgService.GetSliderRange(setting);

                        Slider slider = new Slider();
                        Style sliderStyle = TryFindResource("SlimSlider") as Style;
                        if (sliderStyle != null) { slider.Style = sliderStyle; }
                        slider.Minimum = range.Min;
                        slider.Maximum = range.Max;
                        slider.TickFrequency = range.Tick;
                        slider.IsSnapToTickEnabled = true;
                        slider.Width = 118;
                        slider.VerticalAlignment = VerticalAlignment.Center;
                        slider.Value = value.Value;

                        TextBlock label = new TextBlock();
                        label.Text = PowerCfgService.FormatValue(setting, value);
                        label.FontSize = 11.5;
                        label.Foreground = new SolidColorBrush(Color.FromRgb(0x3A, 0x3F, 0x46));
                        label.VerticalAlignment = VerticalAlignment.Center;
                        label.Margin = new Thickness(10, 0, 0, 0);
                        label.MinWidth = 66;

                        tag.Label = label;
                        slider.Tag = tag;
                        slider.ValueChanged += OnSliderChanged;

                        row.Children.Add(slider);
                        row.Children.Add(label);
                        panel.Children.Add(row);
                        break;
                    }

                default:
                    {
                        TextBlock text = new TextBlock();
                        text.Text = PowerCfgService.FormatValue(setting, value);
                        text.FontSize = 12;
                        text.Foreground = new SolidColorBrush(Color.FromRgb(0x3A, 0x3F, 0x46));
                        panel.Children.Add(text);
                        break;
                    }
            }

            return panel;
        }

        // ============================================================
        //  编辑交互
        // ============================================================
        private void OnToggleChanged(object sender, RoutedEventArgs e)
        {
            if (_suppress) { return; }
            ToggleButton toggle = sender as ToggleButton;
            if (toggle == null) { return; }
            CellTag tag = toggle.Tag as CellTag;
            if (tag == null) { return; }

            SetPending(tag, toggle.IsChecked == true ? 1 : 0);
        }

        private void OnComboChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_suppress) { return; }
            ComboBox combo = sender as ComboBox;
            if (combo == null) { return; }
            CellTag tag = combo.Tag as CellTag;
            if (tag == null) { return; }

            int index = combo.SelectedIndex;
            if (index < 0 || index >= tag.Setting.Options.Count) { return; }

            SetPending(tag, tag.Setting.Options[index].Index);
        }

        private void OnSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_suppress) { return; }
            Slider slider = sender as Slider;
            if (slider == null) { return; }
            CellTag tag = slider.Tag as CellTag;
            if (tag == null) { return; }

            int value = (int)Math.Round(slider.Value);
            if (tag.Label != null)
            {
                tag.Label.Text = PowerCfgService.FormatValue(tag.Setting, value);
            }

            SetPending(tag, value);
        }

        private void SetPending(CellTag tag, int value)
        {
            string key = tag.Setting.Id + "|" + tag.Side;
            int? original = tag.Side == "ac" ? tag.Setting.Ac : tag.Setting.Dc;

            if (original.HasValue && original.Value == value) { _pending.Remove(key); }
            else { _pending[key] = value; }

            UpdatePendingBar();
        }

        private void UpdatePendingBar()
        {
            int count = _pending.Count;
            if (count == 0)
            {
                StatusText.Text = "所有显示的值都与系统中当前设置一致";
                BtnApply.IsEnabled = false;
                BtnRevert.IsEnabled = false;
            }
            else
            {
                StatusText.Text = "有 " + count + " 项更改待应用";
                BtnApply.IsEnabled = true;
                BtnRevert.IsEnabled = true;
            }
        }

        private void OnApply(object sender, RoutedEventArgs e)
        {
            if (_pending.Count == 0) { return; }

            int total = _pending.Count;
            StatusText.Text = "正在写入系统…";
            BtnApply.IsEnabled = false;
            BtnRevert.IsEnabled = false;

            List<PowerCfgService.WriteOutcome> outcomes;
            try
            {
                outcomes = _svc.Apply(new Dictionary<string, int>(_pending), _index);
            }
            catch (Exception ex)
            {
                StatusText.Text = "写入失败：" + ex.Message;
                UpdatePendingBar();
                return;
            }

            _pending.Clear();
            LoadSettings();
            RenderSettings();

            List<PowerCfgService.WriteOutcome> failed = new List<PowerCfgService.WriteOutcome>();
            foreach (PowerCfgService.WriteOutcome outcome in outcomes)
            {
                if (!outcome.Ok) { failed.Add(outcome); }
            }

            if (failed.Count > 0)
            {
                StringBuilder detail = new StringBuilder();
                foreach (PowerCfgService.WriteOutcome f in failed)
                {
                    detail.AppendLine("· " + f.Name + "（" + (f.Side == "ac" ? "接通电源" : "使用电池") + "）：" + f.Message);
                }
                MessageBox.Show(
                    "有 " + failed.Count + " 项没能写入（通常是被设备厂商或固件固定住了）："
                    + Environment.NewLine + Environment.NewLine + detail,
                    "应用结果", MessageBoxButton.OK, MessageBoxImage.Warning);
                StatusText.Text = "已应用 " + (outcomes.Count - failed.Count) + " 项，" + failed.Count + " 项失败";
            }
            else
            {
                StatusText.Text = "已应用 " + total + " 项更改，立即生效";
            }
        }

        private void OnRevert(object sender, RoutedEventArgs e)
        {
            _pending.Clear();
            LoadSettings();
            RenderSettings();
            StatusText.Text = "已放弃未应用的更改";
        }

        // ============================================================
        //  快速方案
        // ============================================================
        private void OnPresetClick(object sender, RoutedEventArgs e)
        {
            Button button = sender as Button;
            if (button == null) { return; }

            string key = button.Tag as string;
            Preset preset = Presets.Find(key);
            if (preset == null) { return; }

            List<Presets.PresetChange> changes = Presets.Diff(preset, _index);
            if (changes.Count == 0)
            {
                MessageBox.Show("当前设置已经符合「" + preset.Name + "」，不需要改动。",
                    "快速方案", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            StringBuilder text = new StringBuilder();
            text.AppendLine("将应用「" + preset.Name + "」，共 " + changes.Count + " 项：");
            text.AppendLine();

            foreach (Presets.PresetChange change in changes)
            {
                text.AppendLine("· " + change.Setting.Name
                    + "（" + (change.Side == "ac" ? "接通电源" : "使用电池") + "）："
                    + PowerCfgService.FormatValue(change.Setting, change.From)
                    + "  →  "
                    + PowerCfgService.FormatValue(change.Setting, change.To));
            }

            text.AppendLine();
            text.Append("只改动上面列出的项目，其余设置保持不变。");

            MessageBoxResult confirm = MessageBox.Show(text.ToString(), "确认应用方案",
                MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (confirm != MessageBoxResult.Yes) { return; }

            Dictionary<string, int> batch = new Dictionary<string, int>();
            foreach (Presets.PresetChange change in changes)
            {
                batch[change.Setting.Id + "|" + change.Side] = change.To;
            }

            try { _svc.Apply(batch, _index); }
            catch (Exception ex)
            {
                StatusText.Text = "方案应用失败：" + ex.Message;
                return;
            }

            _pending.Clear();
            LoadSettings();
            RenderSettings();
            RefreshHidden();
            StatusText.Text = "已应用方案「" + preset.Name + "」";
        }

        // ============================================================
        //  方案切换 / 副本
        // ============================================================
        private void OnSchemeChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_suppress) { return; }

            PowerScheme scheme = SchemeCombo.SelectedItem as PowerScheme;
            if (scheme == null || scheme.Active) { return; }

            if (!_svc.SetActiveScheme(scheme.Guid))
            {
                MessageBox.Show("切换电源方案失败。", "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            _pending.Clear();
            LoadSettings();
            BuildNav();
            RenderSettings();
            StatusText.Text = "已切换到方案「" + scheme.Name + "」";
        }

        private void OnDuplicateScheme(object sender, RoutedEventArgs e)
        {
            MessageBoxResult confirm = MessageBox.Show(
                "将基于当前方案创建一个副本，并立即切换到副本。" + Environment.NewLine + Environment.NewLine +
                "副本只复制设置值，不会影响原方案。",
                "新建方案副本", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (confirm != MessageBoxResult.Yes) { return; }

            PowerCfgResult result = _svc.Run("/duplicatescheme", "SCHEME_CURRENT");
            string joined = result.Text;
            System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(
                joined, "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})");

            if (!m.Success)
            {
                MessageBox.Show("创建副本失败。" + Environment.NewLine + Environment.NewLine + joined,
                    "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            string guid = m.Groups[1].Value;
            const string name = "PowerTuner 自定义";
            _svc.Run("/changename", guid, name);
            _svc.SetActiveScheme(guid);

            _pending.Clear();
            LoadSchemes();
            LoadSettings();
            BuildNav();
            RenderSettings();
            StatusText.Text = "已创建并切换到「" + name + "」";
        }

        // ============================================================
        //  隐藏项
        // ============================================================
        private List<HiddenItem> PendingHidden()
        {
            List<HiddenItem> list = new List<HiddenItem>();
            if (_hidden == null) { return list; }

            foreach (HiddenItem item in _hidden.Interesting)
            {
                if (!_stuck.Contains(item.Key)) { list.Add(item); }
            }
            return list;
        }

        private void RefreshHidden()
        {
            HashSet<string> visible = HiddenSettings.VisibleKeys(_all);
            _hidden = HiddenSettings.Scan(visible);

            List<HiddenItem> pending = PendingHidden();
            if (pending.Count > 0)
            {
                Banner.Visibility = Visibility.Visible;
                BannerText.Text = "系统里还有 " + _hidden.TotalHidden + " 项策略被 Windows 默认隐藏，其中 "
                    + pending.Count + " 项是性能、散热、待机相关的关键调优项（如性能提升模式、核心停放、散热策略）。解锁后即可在本工具中调整。";
                BtnUnhide.IsEnabled = true;
                BtnUnhide.Content = "解锁 " + pending.Count + " 项";
            }
            else
            {
                Banner.Visibility = Visibility.Collapsed;
                BtnUnhide.IsEnabled = false;
            }
        }

        private void OnUnhide(object sender, RoutedEventArgs e)
        {
            if (PendingHidden().Count == 0)
            {
                MessageBox.Show("没有需要解锁的项目了。" + Environment.NewLine + Environment.NewLine +
                    "仍被 Windows 隐藏的策略由固件或驱动固定，软件无法改变它们的可见性。",
                    "解锁隐藏设置", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            BtnUnhide.IsEnabled = false;
            StatusText.Text = "正在请求管理员权限…";

            bool ok = HiddenSettings.RunElevatedUnhide();
            if (!ok)
            {
                StatusText.Text = "已取消管理员授权";
                BtnUnhide.IsEnabled = true;
                return;
            }

            LoadSettings();
            BuildNav();
            RefreshHidden();

            // 这一轮尝试后仍隐藏的，记录下来不再反复提示
            if (_hidden != null)
            {
                foreach (HiddenItem item in _hidden.Interesting)
                {
                    _stuck.Add(item.Key);
                }
                HiddenSettings.SaveStuck(_stuck);
            }

            RefreshHidden();
            RenderSettings();

            int remaining = _hidden == null ? 0 : _hidden.Interesting.Count;
            if (remaining > 0)
            {
                StatusText.Text = "解锁完成；另有 " + remaining + " 项由固件或驱动固定，无法通过软件显示";
            }
            else
            {
                StatusText.Text = "解锁完成，隐藏策略已全部显示";
            }
        }

        // ============================================================
        //  工具页
        // ============================================================
        private void BuildToolsPage()
        {
            int hiddenTotal = _hidden == null ? 0 : _hidden.TotalHidden;
            int hiddenGood = _hidden == null ? 0 : _hidden.Interesting.Count;

            AddHeader("备份与迁移", 2);
            SettingsHost.Children.Add(BuildToolCard("导出当前方案备份",
                "把当前电源方案的全部设置导出为 .pow 文件。重装系统、换机或改坏了都可一键还原。",
                new string[] { "导出…" },
                new RoutedEventHandler[] { delegate { ExportBackup(); } }));

            SettingsHost.Children.Add(BuildToolCard("导入方案备份",
                "从 .pow 文件还原方案。导入后会作为新方案出现在顶部列表，不会覆盖现有方案。",
                new string[] { "导入…" },
                new RoutedEventHandler[] { delegate { ImportBackup(); } }));

            AddHeader("诊断报告", 2);
            SettingsHost.Children.Add(BuildToolCard("电池健康报告",
                "生成完整电池报告（设计容量、实际容量、循环次数、最近三天耗电曲线），生成后用浏览器打开。",
                new string[] { "生成报告" },
                new RoutedEventHandler[] { delegate { BatteryReport(); } }));

            SettingsHost.Children.Add(BuildToolCard("能源效率诊断",
                "监视 60 秒内的电源效率问题（哪些程序阻止睡眠、哪些设备不让 CPU 降频）。需要管理员权限。",
                new string[] { "生成报告" },
                new RoutedEventHandler[] { delegate { EnergyReport(); } }));

            AddHeader("隐藏策略", 1);
            SettingsHost.Children.Add(BuildToolCard("解锁隐藏设置",
                "Windows 把 " + hiddenTotal + " 项电源策略从界面隐藏了，其中 " + hiddenGood
                + " 项是性能、散热、待机相关的关键项。解锁只调整可见性，不改变任何数值。",
                new string[] { "解锁…" },
                new RoutedEventHandler[] { delegate { OnUnhide(this, new RoutedEventArgs()); } }));

            AddHeader("系统面板", 1);
            SettingsHost.Children.Add(BuildToolCard("打开系统自带电源设置",
                "跳到 Windows 设置里的电源页面，或经典的「电源选项」控制面板。",
                new string[] { "系统设置", "经典面板" },
                new RoutedEventHandler[]
                {
                    delegate { OpenTarget("ms-settings:power"); },
                    delegate { OpenTarget("powercfg.cpl"); }
                }));
        }

        private Border BuildToolCard(string title, string description, string[] buttonTexts, RoutedEventHandler[] handlers)
        {
            Border card = new Border();
            card.Style = (Style)FindResource("Card");

            DockPanel dock = new DockPanel();
            dock.Margin = new Thickness(16, 14, 16, 14);
            dock.LastChildFill = true;

            StackPanel bar = new StackPanel();
            bar.Orientation = Orientation.Horizontal;
            bar.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(bar, Dock.Right);

            Style ghost = TryFindResource("BtnGhost") as Style;
            for (int i = 0; i < buttonTexts.Length; i++)
            {
                Button button = new Button();
                if (ghost != null) { button.Style = ghost; }
                button.Content = buttonTexts[i];
                button.Height = 30;
                button.Padding = new Thickness(14, 0, 14, 0);
                button.Margin = new Thickness(8, 0, 0, 0);
                if (i < handlers.Length && handlers[i] != null) { button.Click += handlers[i]; }
                bar.Children.Add(button);
            }
            dock.Children.Add(bar);

            StackPanel info = new StackPanel();
            info.VerticalAlignment = VerticalAlignment.Center;

            TextBlock titleBlock = new TextBlock();
            titleBlock.Text = title;
            titleBlock.FontSize = 13;
            titleBlock.FontWeight = FontWeights.SemiBold;
            titleBlock.Foreground = new SolidColorBrush(Color.FromRgb(0x1B, 0x1E, 0x23));
            info.Children.Add(titleBlock);

            TextBlock descBlock = new TextBlock();
            descBlock.Text = description;
            descBlock.FontSize = 11.5;
            descBlock.Foreground = new SolidColorBrush(Color.FromRgb(0x8A, 0x90, 0x99));
            descBlock.Margin = new Thickness(0, 4, 12, 0);
            descBlock.TextWrapping = TextWrapping.Wrap;
            info.Children.Add(descBlock);

            dock.Children.Add(info);
            card.Child = dock;
            return card;
        }

        // ============================================================
        //  工具动作
        // ============================================================
        private static void OpenTarget(string target)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(target);
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("打开失败：" + ex.Message, "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void ExportBackup()
        {
            SaveFileDialog dialog = new SaveFileDialog();
            dialog.Title = "导出电源方案";
            dialog.Filter = "电源方案备份 (*.pow)|*.pow";
            dialog.FileName = "PowerTuner-方案备份-" + DateTime.Now.ToString("yyyyMMdd") + ".pow";
            if (dialog.ShowDialog() != true) { return; }

            string path = dialog.FileName;
            try { if (File.Exists(path)) { File.Delete(path); } } catch { }

            PowerCfgResult result = _svc.Run("/export", path, "SCHEME_CURRENT");
            if (result.ExitCode == 0 && File.Exists(path))
            {
                StatusText.Text = "已导出到 " + path;
            }
            else
            {
                MessageBox.Show("导出失败：" + Environment.NewLine + Environment.NewLine + result.Text,
                    "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void ImportBackup()
        {
            OpenFileDialog dialog = new OpenFileDialog();
            dialog.Title = "导入电源方案";
            dialog.Filter = "电源方案备份 (*.pow)|*.pow|所有文件 (*.*)|*.*";
            if (dialog.ShowDialog() != true) { return; }

            PowerCfgResult result = _svc.Run("/import", dialog.FileName);
            if (result.ExitCode != 0)
            {
                MessageBox.Show("导入失败：" + Environment.NewLine + Environment.NewLine + result.Text,
                    "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            LoadSchemes();
            StatusText.Text = "已导入方案，可在顶部下拉框中切换";
        }

        private void BatteryReport()
        {
            string path = Path.Combine(Path.GetTempPath(),
                "PowerTuner-电池报告-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".html");

            PowerCfgResult result = _svc.Run("/batteryreport", "/output", path);
            if (result.ExitCode == 0 && File.Exists(path))
            {
                OpenTarget(path);
                StatusText.Text = "电池报告已生成：" + path;
            }
            else
            {
                MessageBox.Show("生成电池报告失败：" + Environment.NewLine + Environment.NewLine + result.Text,
                    "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void EnergyReport()
        {
            string path = Path.Combine(Path.GetTempPath(),
                "PowerTuner-能源报告-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".html");
            StatusText.Text = "正在采集 60 秒能源数据（需要管理员权限），请保持电脑空闲…";

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("powercfg.exe",
                    "/energy /output \"" + path + "\" /duration 60");
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                psi.WindowStyle = ProcessWindowStyle.Hidden;

                using (Process p = Process.Start(psi)) { p.WaitForExit(); }
            }
            catch
            {
                StatusText.Text = "已取消管理员授权";
                return;
            }

            if (File.Exists(path))
            {
                OpenTarget(path);
                StatusText.Text = "能源报告已生成：" + path;
            }
            else
            {
                StatusText.Text = "能源报告生成失败（可能被取消）";
            }
        }

        // ============================================================
        //  分类 / 搜索
        // ============================================================
        private void OnNavSelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_suppress) { return; }

            ListBoxItem item = NavList.SelectedItem as ListBoxItem;
            if (item == null) { return; }

            _category = (string)item.Tag;
            MainScroll.ScrollToTop();
            RenderSettings();
        }

        private void OnSearchChanged(object sender, TextChangedEventArgs e)
        {
            if (SearchHint != null)
            {
                SearchHint.Visibility = string.IsNullOrEmpty(SearchBox.Text)
                    ? Visibility.Visible : Visibility.Collapsed;
            }

            if (_searchTimer == null) { return; }
            _searchTimer.Stop();
            _searchTimer.Start();
        }

        private void OnSearchTick(object sender, EventArgs e)
        {
            _searchTimer.Stop();
            RenderSettings();
        }
    }
}
