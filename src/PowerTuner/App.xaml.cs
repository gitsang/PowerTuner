using System;
using System.Windows;
using System.Windows.Threading;
using PowerTuner.Services;

namespace PowerTuner
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            DispatcherUnhandledException += OnDispatcherUnhandledException;
            AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;

            // 提权模式：只做解锁然后退出，不显示界面
            if (e.Args != null && Array.IndexOf(e.Args, "--unhide") >= 0)
            {
                int count = 0;
                try { count = HiddenSettings.Unhide(); }
                catch { Shutdown(2); return; }

                Shutdown(0);
                return;
            }

            MainWindow window = new MainWindow();
            MainWindow = window;
            window.Show();
        }

        private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            TryLog(e.Exception);
            MessageBox.Show(
                "操作失败：" + Environment.NewLine + Environment.NewLine + e.Exception.Message,
                "PowerTuner", MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true;
        }

        private static void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
        {
            Exception ex = e.ExceptionObject as Exception;
            if (ex != null) { TryLog(ex); }
        }

        private static void TryLog(Exception ex)
        {
            try
            {
                string dir = AppPaths.WorkDirectory;
                System.IO.Directory.CreateDirectory(dir);
                System.IO.File.AppendAllText(
                    System.IO.Path.Combine(dir, "PowerTuner.log"),
                    "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + ex + Environment.NewLine,
                    System.Text.Encoding.UTF8);
            }
            catch
            {
                // 记录日志本身失败就放弃，不要二次抛错
            }
        }
    }

    internal static class AppPaths
    {
        /// <summary>运行目录：%LOCALAPPDATA%\PowerTuner</summary>
        public static string WorkDirectory
        {
            get
            {
                return System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "PowerTuner");
            }
        }
    }
}
