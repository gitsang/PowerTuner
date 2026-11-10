using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using PowerTuner.Models;

namespace PowerTuner.Models
{
    public enum SettingKind
    {
        Toggle,
        Combo,
        Slider,
        Text
    }

    public sealed class PowerOption
    {
        public int Index { get; set; }
        public string Name { get; set; }
    }

    public sealed class PowerSetting
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Alias { get; set; }
        public string Sub { get; set; }
        public string SubName { get; set; }
        public string Unit { get; set; }

        public int? Min { get; set; }
        public int? Max { get; set; }
        public int? Increment { get; set; }

        public List<PowerOption> Options { get; set; }
        public int? Ac { get; set; }
        public int? Dc { get; set; }
        public SettingKind Kind { get; set; }

        public PowerSetting()
        {
            Options = new List<PowerOption>();
            Alias = string.Empty;
            SubName = string.Empty;
            Unit = string.Empty;
        }
    }

    public sealed class PowerScheme
    {
        public string Guid { get; set; }
        public string Name { get; set; }
        public bool Active { get; set; }
    }

    public sealed class PresetItem
    {
        public string Id { get; set; }
        public int? Ac { get; set; }
        public int? Dc { get; set; }
    }

    public sealed class Preset
    {
        public string Key { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public List<PresetItem> Items { get; set; }

        public Preset()
        {
            Items = new List<PresetItem>();
        }
    }

    public sealed class HiddenItem
    {
        public string Sub { get; set; }
        public string SubName { get; set; }
        public string Id { get; set; }
        public string Name { get; set; }

        public string Key
        {
            get { return (Sub + "|" + Id).ToLowerInvariant(); }
        }
    }
}

namespace PowerTuner.Services
{
    public sealed class PowerCfgResult
    {
        public int ExitCode { get; set; }
        public string[] Lines { get; set; }
        public string Text { get; set; }

        public PowerCfgResult()
        {
            Lines = new string[0];
            Text = string.Empty;
        }
    }

    /// <summary>
    /// powercfg 的封装：读取电源方案与全部策略、写入数值。
    /// 不硬编码策略列表，一切以 powercfg 的实际输出为准。
    /// </summary>
    public sealed class PowerCfgService
    {
        private const string ExeName = "powercfg.exe";

        [DllImport("kernel32.dll")]
        private static extern int GetOEMCP();

        private static Encoding _outputEncoding;
        private static readonly object EncLock = new object();

        private static Encoding OutputEncoding
        {
            get
            {
                lock (EncLock)
                {
                    if (_outputEncoding == null)
                    {
                        try { _outputEncoding = Encoding.GetEncoding(GetOEMCP()); }
                        catch { _outputEncoding = Encoding.Default; }
                    }
                    return _outputEncoding;
                }
            }
        }

        // ---------- 进程调用 ----------
        private static string Quote(string value)
        {
            if (value == null) { return "\"\""; }
            if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) { return value; }
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        public PowerCfgResult Run(params string[] args)
        {
            ProcessStartInfo psi = new ProcessStartInfo(ExeName);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = OutputEncoding;
            psi.StandardErrorEncoding = OutputEncoding;

            StringBuilder argLine = new StringBuilder();
            for (int i = 0; i < args.Length; i++)
            {
                if (i > 0) { argLine.Append(' '); }
                argLine.Append(Quote(args[i]));
            }
            psi.Arguments = argLine.ToString();

            using (Process proc = Process.Start(psi))
            {
                string stdout = proc.StandardOutput.ReadToEnd();
                string stderr = proc.StandardError.ReadToEnd();
                proc.WaitForExit();

                string all = stdout;
                if (!string.IsNullOrEmpty(stderr)) { all += Environment.NewLine + stderr; }

                string[] lines = all.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
                return new PowerCfgResult { ExitCode = proc.ExitCode, Lines = lines, Text = all };
            }
        }

        // ---------- 电源方案 ----------
        private static readonly Regex SchemeRegex = new Regex(
            @"GUID\s*[:：]\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*(?:\((.*?)\))?\s*(\*)?\s*$",
            RegexOptions.Compiled);

        public List<PowerScheme> GetSchemes()
        {
            List<PowerScheme> result = new List<PowerScheme>();
            PowerCfgResult res = Run("/list");

            foreach (string raw in res.Lines)
            {
                Match m = SchemeRegex.Match(raw);
                if (!m.Success) { continue; }

                string name = m.Groups[2].Value;
                if (string.IsNullOrWhiteSpace(name)) { name = m.Groups[1].Value; }

                result.Add(new PowerScheme
                {
                    Guid = m.Groups[1].Value,
                    Name = name.Trim(),
                    Active = m.Groups[3].Value == "*"
                });
            }

            bool anyActive = false;
            foreach (PowerScheme s in result) { if (s.Active) { anyActive = true; break; } }

            if (!anyActive && result.Count > 0)
            {
                PowerCfgResult active = Run("/getactivescheme");
                if (active.ExitCode == 0 && active.Lines.Length > 0)
                {
                    Match m = SchemeRegex.Match(active.Lines[0]);
                    if (m.Success)
                    {
                        foreach (PowerScheme s in result)
                        {
                            if (s.Guid.Equals(m.Groups[1].Value, StringComparison.OrdinalIgnoreCase)) { s.Active = true; }
                        }
                    }
                }
            }

            return result;
        }

        public bool SetActiveScheme(string guid)
        {
            return Run("/setactive", guid).ExitCode == 0;
        }

        // ---------- 策略解析 ----------
        private static readonly Regex EntityRegex = new Regex(
            @"^(?<label>.*?)\s*GUID\s*[:：]\s*(?<guid>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*(?:\((?<name>.*)\))?\s*$",
            RegexOptions.Compiled);

        private static readonly Regex AliasRegex = new Regex(
            @"^(?:GUID\s*别名|GUID\s*Alias|别名|Alias)\s*[:：]\s*(?<v>\S+)\s*$", RegexOptions.Compiled);

        private static readonly Regex MinRegex = new Regex(
            @"^(?:最小可能的设置|Minimum Possible Setting)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex MaxRegex = new Regex(
            @"^(?:最大可能的设置|Maximum Possible Setting)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex IncRegex = new Regex(
            @"^(?:可能的设置增量|Possible Setting Increment)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex UnitRegex = new Regex(
            @"^(?:可能的设置单位|Possible Setting Units?)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex OptionIndexRegex = new Regex(
            @"^(?:可能的设置索引|Possible Setting Index)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex OptionNameRegex = new Regex(
            @"^(?:可能的设置友好名称|Possible Setting Friendly Name)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex CurrentAcRegex = new Regex(
            @"^(?:当前交流电源设置索引|Current AC Power Setting Index)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static readonly Regex CurrentDcRegex = new Regex(
            @"^(?:当前直流电源设置索引|Current DC Power Setting Index)\s*[:：]\s*(?<v>.+)$", RegexOptions.Compiled);

        private static int? ParseIndex(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) { return null; }
            string value = text.Trim();

            if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            {
                int hex;
                if (int.TryParse(value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out hex)) { return hex; }
                return null;
            }

            int dec;
            if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out dec)) { return dec; }
            return null;
        }

        public List<PowerSetting> GetSettings()
        {
            List<PowerSetting> result = new List<PowerSetting>();
            PowerCfgResult res = Run("/query", "SCHEME_CURRENT");

            string subGuid = string.Empty;
            string subName = string.Empty;
            PowerSetting current = null;
            int? pendingOptionIndex = null;

            foreach (string raw in res.Lines)
            {
                if (raw == null) { continue; }
                string line = raw.Trim();
                if (line.Length == 0) { continue; }

                Match entity = EntityRegex.Match(line);
                if (entity.Success)
                {
                    string label = entity.Groups["label"].Value;
                    string guid = entity.Groups["guid"].Value;
                    string name = entity.Groups["name"].Value;

                    if (label.IndexOf("电源方案", StringComparison.Ordinal) >= 0 ||
                        label.IndexOf("Power Scheme", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        continue;
                    }

                    bool isSubgroup =
                        label.IndexOf("子组", StringComparison.Ordinal) >= 0 ||
                        label.IndexOf("Subgroup", StringComparison.OrdinalIgnoreCase) >= 0;

                    if (isSubgroup)
                    {
                        subGuid = guid;
                        subName = name;
                        current = null;
                        continue;
                    }

                    current = new PowerSetting
                    {
                        Id = guid,
                        Name = name,
                        Sub = subGuid,
                        SubName = subName
                    };
                    pendingOptionIndex = null;
                    result.Add(current);
                    continue;
                }

                if (current == null) { continue; }

                Match m = AliasRegex.Match(line);
                if (m.Success) { current.Alias = m.Groups["v"].Value; continue; }

                m = MinRegex.Match(line);
                if (m.Success) { current.Min = ParseIndex(m.Groups["v"].Value); continue; }

                m = MaxRegex.Match(line);
                if (m.Success) { current.Max = ParseIndex(m.Groups["v"].Value); continue; }

                m = IncRegex.Match(line);
                if (m.Success) { current.Increment = ParseIndex(m.Groups["v"].Value); continue; }

                m = UnitRegex.Match(line);
                if (m.Success) { current.Unit = m.Groups["v"].Value.Trim(); continue; }

                m = OptionIndexRegex.Match(line);
                if (m.Success) { pendingOptionIndex = ParseIndex(m.Groups["v"].Value); continue; }

                m = OptionNameRegex.Match(line);
                if (m.Success)
                {
                    if (pendingOptionIndex.HasValue)
                    {
                        current.Options.Add(new PowerOption
                        {
                            Index = pendingOptionIndex.Value,
                            Name = m.Groups["v"].Value.Trim()
                        });
                        pendingOptionIndex = null;
                    }
                    continue;
                }

                m = CurrentAcRegex.Match(line);
                if (m.Success) { current.Ac = ParseIndex(m.Groups["v"].Value); continue; }

                m = CurrentDcRegex.Match(line);
                if (m.Success) { current.Dc = ParseIndex(m.Groups["v"].Value); continue; }
            }

            foreach (PowerSetting s in result) { ResolveKind(s); }
            return result;
        }

        private static readonly string[] BooleanNames = new string[]
        {
            "关闭", "开启", "已禁用", "已启用", "禁用", "启用",
            "Off", "On", "Disabled", "Enabled", "允许", "不允许", "否", "是"
        };

        private static void ResolveKind(PowerSetting s)
        {
            if (s.Options.Count >= 2)
            {
                bool boolean = false;
                if (s.Options.Count == 2)
                {
                    string a = s.Options[0].Name;
                    string b = s.Options[1].Name;
                    boolean = IsBooleanName(a) && IsBooleanName(b);
                }
                s.Kind = boolean ? SettingKind.Toggle : SettingKind.Combo;
                return;
            }

            s.Kind = s.Max.HasValue ? SettingKind.Slider : SettingKind.Text;
        }

        private static bool IsBooleanName(string name)
        {
            foreach (string candidate in BooleanNames)
            {
                if (string.Equals(name, candidate, StringComparison.OrdinalIgnoreCase)) { return true; }
            }
            return false;
        }

        // ---------- 写入 ----------
        public sealed class WriteOutcome
        {
            public string SettingId { get; set; }
            public string Side { get; set; }
            public string Name { get; set; }
            public bool Ok { get; set; }
            public string Message { get; set; }
        }

        /// <param name="changes">键为 "设置Id|ac" 或 "设置Id|dc"，值为目标索引</param>
        public List<WriteOutcome> Apply(Dictionary<string, int> changes, IDictionary<string, PowerSetting> index)
        {
            List<WriteOutcome> outcomes = new List<WriteOutcome>();

            foreach (KeyValuePair<string, int> pair in changes)
            {
                string[] parts = pair.Key.Split('|');
                if (parts.Length != 2) { continue; }

                string id = parts[0];
                string side = parts[1];

                PowerSetting setting;
                if (!index.TryGetValue(id, out setting) || setting == null) { continue; }

                string verb = side == "ac" ? "/setacvalueindex" : "/setdcvalueindex";
                PowerCfgResult res = Run(verb, "SCHEME_CURRENT", setting.Sub, id,
                    pair.Value.ToString(CultureInfo.InvariantCulture));

                outcomes.Add(new WriteOutcome
                {
                    SettingId = id,
                    Side = side,
                    Name = setting.Name,
                    Ok = res.ExitCode == 0,
                    Message = res.Text.Trim()
                });
            }

            Run("/setactive", "SCHEME_CURRENT");
            return outcomes;
        }

        // ---------- 显示格式 ----------
        public static string FormatValue(PowerSetting setting, int? value)
        {
            if (!value.HasValue) { return "—"; }

            if (setting.Kind == SettingKind.Toggle || setting.Kind == SettingKind.Combo)
            {
                foreach (PowerOption option in setting.Options)
                {
                    if (option.Index == value.Value) { return option.Name; }
                }
                return "索引 " + value.Value;
            }

            if (setting.Unit == "%") { return value.Value + "%"; }
            if (setting.Unit == "秒") { return FormatSeconds(value.Value); }
            if (string.IsNullOrEmpty(setting.Unit)) { return value.Value.ToString(CultureInfo.InvariantCulture); }
            return value.Value + " " + setting.Unit;
        }

        public static string FormatSeconds(int seconds)
        {
            if (seconds <= 0) { return "从不"; }
            if (seconds < 60) { return seconds + " 秒"; }

            int minutes = seconds / 60;
            int rest = seconds % 60;

            if (minutes >= 60)
            {
                int hours = minutes / 60;
                int mins = minutes % 60;
                if (mins == 0) { return hours + " 小时"; }
                return hours + " 小时 " + mins + " 分";
            }

            if (rest == 0) { return minutes + " 分钟"; }
            return minutes + " 分 " + rest + " 秒";
        }

        public sealed class SliderRange
        {
            public double Min { get; set; }
            public double Max { get; set; }
            public double Tick { get; set; }
        }

        public static SliderRange GetSliderRange(PowerSetting setting)
        {
            double max = 100;

            if (setting.Unit == "%") { max = 100; }
            else if (setting.Unit == "秒") { max = 7200; }
            else if (setting.Max.HasValue && setting.Max.Value > 0 && setting.Max.Value <= 100000) { max = setting.Max.Value; }
            else { max = 1000; }

            if (setting.Ac.HasValue && setting.Ac.Value > max) { max = setting.Ac.Value; }
            if (setting.Dc.HasValue && setting.Dc.Value > max) { max = setting.Dc.Value; }

            double tick = 1;
            if (setting.Unit == "秒" && max > 120)
            {
                bool aligned = true;
                if (setting.Ac.HasValue && setting.Ac.Value % 30 != 0) { aligned = false; }
                if (setting.Dc.HasValue && setting.Dc.Value % 30 != 0) { aligned = false; }
                if (aligned) { tick = 30; }
            }

            return new SliderRange { Min = 0, Max = max, Tick = tick };
        }
    }
}
