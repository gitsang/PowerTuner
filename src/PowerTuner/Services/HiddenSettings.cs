using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using PowerTuner.Models;

namespace PowerTuner.Services
{
    public sealed class HiddenScan
    {
        public int TotalHidden { get; set; }
        public List<HiddenItem> Interesting { get; set; }

        public HiddenScan()
        {
            Interesting = new List<HiddenItem>();
        }
    }

    /// <summary>
    /// 探测被 Windows 隐藏的电源策略，并提供解锁（需要管理员权限）。
    /// 隐藏状态存放在注册表 HKLM\...\Power\PowerSettings\&lt;子组&gt;\&lt;策略&gt; 的 Attributes 值里。
    /// </summary>
    public static class HiddenSettings
    {
        private const string RootPath = @"SYSTEM\CurrentControlSet\Control\Power\PowerSettings";

        private static readonly string[] InterestingPatterns = new string[]
        {
            "boost mode", "boost policy", "core parking", "idle disable",
            "idle time check", "idle demote threshold", "idle promote threshold",
            "performance time check", "increase threshold", "decrease threshold",
            "increase policy", "decrease policy", "increase time", "decrease time",
            "system cooling policy", "unattended sleep timeout",
            "console lock display off timeout", "connectivity in standby",
            "allow standby states", "usb 3 link power management",
            "energy saver", "processor performance history"
        };

        private static readonly Regex IndirectString = new Regex(
            @"^@[^,]+,-?\d+,(.*)$", RegexOptions.Compiled);

        private static string PlainName(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) { return string.Empty; }
            string text = raw.Trim();
            Match m = IndirectString.Match(text);
            if (m.Success) { return m.Groups[1].Value.Trim(); }
            return text;
        }

        private static bool IsInteresting(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) { return false; }
            string lower = name.ToLowerInvariant();
            foreach (string pattern in InterestingPatterns)
            {
                if (lower.Contains(pattern)) { return true; }
            }
            return false;
        }

        /// <summary>扫描注册表，返回「未出现在 powercfg /query 中」的策略。</summary>
        public static HiddenScan Scan(HashSet<string> visibleKeys)
        {
            HiddenScan scan = new HiddenScan();

            try
            {
                using (RegistryKey root = Registry.LocalMachine.OpenSubKey(RootPath))
                {
                    if (root == null) { return scan; }

                    foreach (string subName in root.GetSubKeyNames())
                    {
                        using (RegistryKey sub = root.OpenSubKey(subName))
                        {
                            if (sub == null) { continue; }

                            string subTitle = PlainName(Convert.ToString(sub.GetValue("FriendlyName")));

                            foreach (string settingName in sub.GetSubKeyNames())
                            {
                                using (RegistryKey setting = sub.OpenSubKey(settingName))
                                {
                                    if (setting == null) { continue; }

                                    string title = PlainName(Convert.ToString(setting.GetValue("FriendlyName")));
                                    if (string.IsNullOrEmpty(title)) { continue; }

                                    string key = (subName + "|" + settingName).ToLowerInvariant();
                                    if (visibleKeys.Contains(key)) { continue; }

                                    scan.TotalHidden++;

                                    if (IsInteresting(title))
                                    {
                                        scan.Interesting.Add(new HiddenItem
                                        {
                                            Sub = subName,
                                            SubName = subTitle,
                                            Id = settingName,
                                            Name = title
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
            catch
            {
                // 注册表读不到就当作没有隐藏项，不影响主流程
            }

            return scan;
        }

        // ---------- 已尝试且无效的项（持久化，避免反复提示） ----------
        private static string StuckFile
        {
            get { return Path.Combine(AppPaths.WorkDirectory, "unhide.stuck.txt"); }
        }

        public static HashSet<string> LoadStuck()
        {
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(StuckFile))
                {
                    foreach (string line in File.ReadAllLines(StuckFile))
                    {
                        string trimmed = line.Trim();
                        if (trimmed.Length > 0) { set.Add(trimmed); }
                    }
                }
            }
            catch { }
            return set;
        }

        public static void SaveStuck(IEnumerable<string> keys)
        {
            try
            {
                Directory.CreateDirectory(AppPaths.WorkDirectory);
                File.WriteAllLines(StuckFile, keys);
            }
            catch { }
        }

        // ---------- 解锁 ----------
        /// <summary>把匹配到的隐藏策略的 Attributes 设为 2（显示）。需要管理员权限。</summary>
        public static int Unhide()
        {
            int changed = 0;

            using (RegistryKey root = Registry.LocalMachine.OpenSubKey(RootPath, true))
            {
                if (root == null) { return 0; }

                foreach (string subName in root.GetSubKeyNames())
                {
                    using (RegistryKey sub = root.OpenSubKey(subName, true))
                    {
                        if (sub == null) { continue; }

                        foreach (string settingName in sub.GetSubKeyNames())
                        {
                            using (RegistryKey setting = sub.OpenSubKey(settingName, true))
                            {
                                if (setting == null) { continue; }

                                string title = PlainName(Convert.ToString(setting.GetValue("FriendlyName")));
                                if (!IsInteresting(title)) { continue; }

                                try
                                {
                                    setting.SetValue("Attributes", 2, RegistryValueKind.DWord);
                                    changed++;
                                }
                                catch { }
                            }
                        }
                    }
                }
            }

            return changed;
        }

        /// <summary>以管理员身份重新启动自身执行 --unhide，等待其结束。</summary>
        public static bool RunElevatedUnhide()
        {
            try
            {
                string exe = Assembly.GetEntryAssembly().Location;
                ProcessStartInfo psi = new ProcessStartInfo(exe, "--unhide");
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                psi.WindowStyle = ProcessWindowStyle.Hidden;

                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode == 0;
                }
            }
            catch
            {
                // 用户取消 UAC 或启动失败
                return false;
            }
        }

        /// <summary>把 /query 里的策略拼成 "子组|策略" 集合，用于比对可见性。</summary>
        public static HashSet<string> VisibleKeys(IEnumerable<PowerSetting> settings)
        {
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (PowerSetting s in settings)
            {
                set.Add((s.Sub + "|" + s.Id).ToLowerInvariant());
            }
            return set;
        }
    }
}
