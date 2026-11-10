// ============================================================
//  PowerTuner.exe 启动器
//  作用：把内嵌的 PowerShell / XAML 资源释放到 %LOCALAPPDATA%\PowerTuner，
//        再用无窗口方式拉起 WPF 界面。编译成一个独立的单文件 exe。
// ============================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

internal static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    private const uint MB_ICONERROR = 0x10;

    private static readonly string[] ResourceNames = new string[]
    {
        "PowerTuner.ps1",
        "PowerTuner.Core.ps1",
        "MainWindow.xaml",
        "Theme.xaml",
        "Unhide-PowerSettings.ps1"
    };

    [STAThread]
    private static void Main()
    {
        try
        {
            string workDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PowerTuner");

            try
            {
                Directory.CreateDirectory(workDir);
            }
            catch (Exception ex)
            {
                MessageBoxW(IntPtr.Zero,
                    "无法创建运行目录：\r\n" + workDir + "\r\n\r\n" + ex.Message,
                    "PowerTuner", MB_ICONERROR);
                return;
            }

            Assembly asm = Assembly.GetExecutingAssembly();

            foreach (string name in ResourceNames)
            {
                try
                {
                    using (Stream src = asm.GetManifestResourceStream(name))
                    {
                        if (src == null)
                        {
                            continue;
                        }

                        string target = Path.Combine(workDir, name);
                        using (FileStream dst = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.Read))
                        {
                            src.CopyTo(dst);
                        }
                    }
                }
                catch
                {
                    // 单个文件失败（例如被占用）不致命，继续用已存在的副本
                }
            }

            string script = Path.Combine(workDir, "PowerTuner.ps1");
            if (!File.Exists(script))
            {
                MessageBoxW(IntPtr.Zero,
                    "内置文件解压失败：未找到 PowerTuner.ps1。\r\n\r\n请确认 exe 文件完整（未被杀毒软件截断）。",
                    "PowerTuner", MB_ICONERROR);
                return;
            }

            ProcessStartInfo info = new ProcessStartInfo("powershell.exe");
            info.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = workDir;

            Process.Start(info);
        }
        catch (Exception ex)
        {
            MessageBoxW(IntPtr.Zero,
                "PowerTuner 启动失败：\r\n\r\n" + ex.Message,
                "PowerTuner", MB_ICONERROR);
        }
    }
}
