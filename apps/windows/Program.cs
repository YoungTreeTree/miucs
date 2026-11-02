using System;
using System.Threading;
using System.Windows;

namespace Miucs.Windows;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--smoke-test")
        {
            try { WindowsSmokeTests.Run(args.Length > 1 ? args[1] : "build/windows-smoke"); return 0; }
            catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
        using var reopen = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Miucs.Windows.ShowSettings");
        using var instance = new Mutex(true, @"Local\Miucs.Windows", out bool first);
        if (!first) { reopen.Set(); return 0; }
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        try
        {
            using var host = new DesktopHost(app);
            var registration = ThreadPool.RegisterWaitForSingleObject(reopen, (_, _) =>
            {
                if (!app.Dispatcher.HasShutdownStarted) app.Dispatcher.BeginInvoke(new Action(host.ShowSettings));
            }, null, Timeout.Infinite, false);
            try { app.Run(); }
            finally { registration.Unregister(null); }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Miucs 启动失败", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }
}
