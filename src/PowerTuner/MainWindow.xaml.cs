using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PowerTuner.Models;
using PowerTuner.Services;

namespace PowerTuner
{
    public partial class MainWindow : Window
    {
        private readonly PowerCfgService _powerCfg = new PowerCfgService();
        private readonly Dictionary<string, PowerSetting> _index = new Dictionary<string, PowerSetting>();
        private List<PowerSetting> _allSettings = new List<PowerSetting>();
        private string _category = "common";

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
            "common", "sleep", "buttons", "cpu", "disk", "battery", "net", "gpu", "other", "all"
        };

        private static readonly string[] NavLabels = new string[]
        {
            "常用设置", "睡眠与显示", "电源按钮与合盖", "处理器", "磁盘与存储",
            "电池", "网络、USB 与总线", "显卡", "其他策略", "全部设置"
        };

        public MainWindow()
        {
            InitializeComponent();
            Loaded += OnLoaded;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            try
            {
                LoadSchemes();
                _allSettings = _powerCfg.GetSettings();

                _index.Clear();
                foreach (PowerSetting setting in _allSettings) { _index[setting.Id] = setting; }

                BuildNav();
                if (NavList.Items.Count > 0) { NavList.SelectedIndex = 0; }
                RenderSettings();

                StatusText.Text = "共解析到 " + _allSettings.Count + " 条电源策略";
            }
            catch (Exception ex)
            {
                StatusText.Text = "读取电源策略失败：" + ex.Message;
                MessageBox.Show(ex.ToString(), "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void LoadSchemes()
        {
            List<PowerScheme> schemes = _powerCfg.GetSchemes();
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

        private void BuildNav()
        {
            NavList.Items.Clear();
            for (int i = 0; i < NavKeys.Length; i++)
            {
                int count = CountForCategory(NavKeys[i]);

                DockPanel panel = new DockPanel();

                TextBlock number = new TextBlock();
                number.Text = count.ToString();
                number.FontSize = 11;
                number.Foreground = new SolidColorBrush(Color.FromRgb(0xA9, 0xAE, 0xB6));
                number.VerticalAlignment = VerticalAlignment.Center;
                DockPanel.SetDock(number, Dock.Right);
                panel.Children.Add(number);

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

        private int CountForCategory(string key)
        {
            if (key == "all") { return _allSettings.Count; }

            if (key == "common")
            {
                int n = 0;
                foreach (string id in CommonIds) { if (_index.ContainsKey(id)) { n++; } }
                return n;
            }

            int count = 0;
            foreach (PowerSetting setting in _allSettings)
            {
                if (CategoryFor(setting.Sub) == key) { count++; }
            }
            return count;
        }

        private static string CategoryFor(string subGuid)
        {
            string key;
            if (subGuid != null && CategoryOfSub.TryGetValue(subGuid.ToLowerInvariant(), out key)) { return key; }
            return "other";
        }

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

            foreach (PowerSetting setting in _allSettings)
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

            List<PowerSetting> items = Filtered();
            if (items.Count == 0)
            {
                TextBlock empty = new TextBlock();
                empty.Text = "这个分类下暂时没有可调整的策略";
                empty.Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0xA0, 0xA8));
                empty.Margin = new Thickness(4, 40, 0, 0);
                SettingsHost.Children.Add(empty);
                return;
            }

            string lastSub = null;
            foreach (PowerSetting setting in items)
            {
                string subName = string.IsNullOrEmpty(setting.SubName) ? "未分类" : setting.SubName;

                if (subName != lastSub)
                {
                    TextBlock header = new TextBlock();
                    header.Text = subName + "   ·   " + CountInSub(items, setting.Sub) + " 项";
                    header.FontSize = 11.5;
                    header.FontWeight = FontWeights.SemiBold;
                    header.Foreground = new SolidColorBrush(Color.FromRgb(0x8A, 0x90, 0x99));
                    header.Margin = new Thickness(2, 14, 0, 8);
                    SettingsHost.Children.Add(header);
                    lastSub = subName;
                }

                SettingsHost.Children.Add(BuildCard(setting));
            }
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

            StackPanel dcCell = BuildValueCell(setting, setting.Dc, "使用电池");
            dcCell.Width = 216;
            DockPanel.SetDock(dcCell, Dock.Right);
            dock.Children.Add(dcCell);

            StackPanel acCell = BuildValueCell(setting, setting.Ac, "接通电源");
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
                sub.Text = setting.SubName + (string.IsNullOrEmpty(setting.Alias) ? "" : " · " + setting.Alias);
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

        private static StackPanel BuildValueCell(PowerSetting setting, int? value, string caption)
        {
            StackPanel panel = new StackPanel();
            panel.Margin = new Thickness(8, 0, 0, 0);
            panel.VerticalAlignment = VerticalAlignment.Center;

            TextBlock head = new TextBlock();
            head.Text = caption;
            head.FontSize = 10.5;
            head.Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0xA0, 0xA8));
            head.Margin = new Thickness(0, 0, 0, 5);
            panel.Children.Add(head);

            TextBlock text = new TextBlock();
            text.Text = PowerCfgService.FormatValue(setting, value);
            text.FontSize = 12;
            text.Foreground = new SolidColorBrush(Color.FromRgb(0x3A, 0x3F, 0x46));
            text.TextTrimming = TextTrimming.CharacterEllipsis;
            panel.Children.Add(text);

            return panel;
        }

        private void OnNavSelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            ListBoxItem item = NavList.SelectedItem as ListBoxItem;
            if (item == null) { return; }

            _category = (string)item.Tag;
            RenderSettings();
        }

        private void OnSearchChanged(object sender, TextChangedEventArgs e)
        {
            if (SearchHint != null)
            {
                SearchHint.Visibility = string.IsNullOrEmpty(SearchBox.Text)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
            }
            if (_allSettings.Count > 0) { RenderSettings(); }
        }
    }
}
