using System.Collections.Generic;
using PowerTuner.Models;

namespace PowerTuner.Services
{
    /// <summary>快速方案的定义与差异计算。</summary>
    public static class Presets
    {
        public sealed class PresetChange
        {
            public PowerSetting Setting { get; set; }
            public string Side { get; set; }
            public int From { get; set; }
            public int To { get; set; }
        }

        public static List<Preset> All()
        {
            List<Preset> list = new List<Preset>();

            Preset desk = new Preset
            {
                Key = "desk",
                Name = "常插电 · 工作站",
                Description = "关屏 15 分、睡眠 30 分、硬盘不休眠、处理器全速（仅改接通电源）"
            };
            desk.Items.Add(Item("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e", 900, null));
            desk.Items.Add(Item("29f6c1db-86da-48c5-9fdb-f2b67b1f44da", 1800, null));
            desk.Items.Add(Item("6738e2c4-e8a5-4a42-b16a-e040e769756e", 0, null));
            desk.Items.Add(Item("893dee8e-2bef-41e0-89c6-b55d0929964c", 5, null));
            desk.Items.Add(Item("bc5038f7-23e0-4960-96da-33abaf5935ec", 100, null));
            desk.Items.Add(Item("03680956-93bc-4294-bba6-4e0f09bb717f", 0, null));
            list.Add(desk);

            Preset noSleep = new Preset
            {
                Key = "nosleep",
                Name = "长任务 · 不睡眠",
                Description = "屏幕与系统都不进入睡眠，适合编译、下载、跑测试（仅改接通电源）"
            };
            noSleep.Items.Add(Item("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e", 0, null));
            noSleep.Items.Add(Item("29f6c1db-86da-48c5-9fdb-f2b67b1f44da", 0, null));
            noSleep.Items.Add(Item("9d7815a6-7ee4-497e-8888-515a05f02364", 0, null));
            noSleep.Items.Add(Item("6738e2c4-e8a5-4a42-b16a-e040e769756e", 0, null));
            noSleep.Items.Add(Item("03680956-93bc-4294-bba6-4e0f09bb717f", 1, null));
            list.Add(noSleep);

            Preset travel = new Preset
            {
                Key = "travel",
                Name = "差旅 · 省电",
                Description = "电池下快速关屏、降亮度、提高低电量提醒阈值"
            };
            travel.Items.Add(Item("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e", 300, 120));
            travel.Items.Add(Item("29f6c1db-86da-48c5-9fdb-f2b67b1f44da", 900, 300));
            travel.Items.Add(Item("aded5e82-b909-4619-9949-f5d71dac0bcb", 100, 50));
            travel.Items.Add(Item("8183ba9a-e910-48da-8769-14ae6dc1170a", 10, 10));
            travel.Items.Add(Item("9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469", 5, 5));
            list.Add(travel);

            Preset reset = new Preset
            {
                Key = "reset",
                Name = "恢复默认节奏",
                Description = "把时间类参数还原为 Windows 平衡方案的出厂取值"
            };
            reset.Items.Add(Item("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e", 600, 300));
            reset.Items.Add(Item("29f6c1db-86da-48c5-9fdb-f2b67b1f44da", 1800, 900));
            reset.Items.Add(Item("6738e2c4-e8a5-4a42-b16a-e040e769756e", 1200, 600));
            reset.Items.Add(Item("893dee8e-2bef-41e0-89c6-b55d0929964c", 5, 5));
            reset.Items.Add(Item("bc5038f7-23e0-4960-96da-33abaf5935ec", 100, 100));
            list.Add(reset);

            return list;
        }

        private static PresetItem Item(string id, int? ac, int? dc)
        {
            return new PresetItem { Id = id, Ac = ac, Dc = dc };
        }

        public static Preset Find(string key)
        {
            foreach (Preset p in All())
            {
                if (p.Key == key) { return p; }
            }
            return null;
        }

        /// <summary>算出该方案相对当前值真正会变动的项目（只返回有差异的）。</summary>
        public static List<PresetChange> Diff(Preset preset, IDictionary<string, PowerSetting> index)
        {
            List<PresetChange> changes = new List<PresetChange>();

            foreach (PresetItem item in preset.Items)
            {
                PowerSetting setting;
                if (!index.TryGetValue(item.Id, out setting) || setting == null) { continue; }

                if (item.Ac.HasValue && setting.Ac.HasValue && setting.Ac.Value != item.Ac.Value)
                {
                    changes.Add(new PresetChange
                    {
                        Setting = setting,
                        Side = "ac",
                        From = setting.Ac.Value,
                        To = item.Ac.Value
                    });
                }

                if (item.Dc.HasValue && setting.Dc.HasValue && setting.Dc.Value != item.Dc.Value)
                {
                    changes.Add(new PresetChange
                    {
                        Setting = setting,
                        Side = "dc",
                        From = setting.Dc.Value,
                        To = item.Dc.Value
                    });
                }
            }

            return changes;
        }
    }
}
