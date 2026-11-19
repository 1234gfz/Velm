using System;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace PBZTweaker;

public partial class App : Application
{
    private static readonly string LogPath =
        Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "startup.log");

    private Mutex _mutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        bool created;
        _mutex = new Mutex(true, @"Global\PBZTweaker_SingleInstance", out created);
        if (!created)
        {
            Log("已经有实例在跑了，直接退出");
            Shutdown(0);
            return;
        }

        Log("startup " + DateTime.Now.ToString("HH:mm:ss"));
        DispatcherUnhandledException += OnUnhandled;
        AppDomain.CurrentDomain.UnhandledException += (s, args) =>
            Log("domain: " + args.ExceptionObject);
        try
        {
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;

            var w = new MainWindow();
            w.Closed += (s, a) => Log("main window closed");

            // 关键：不 Show，但要先把 HWND 建出来，否则注册不了热键
            var hwnd = new WindowInteropHelper(w).EnsureHandle();
            MainWindow = w;
            Log("window created hidden, hwnd=" + hwnd);
        }
        catch (Exception ex)
        {
            Log("startup failed: " + ex);
            MessageBox.Show(ex.ToString(), "启动失败");
            Shutdown(1);
        }
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log("dispatcher: " + e.Exception);
        e.Handled = true;
    }

    private static void Log(string msg)
    {
        try { File.AppendAllText(LogPath, msg + Environment.NewLine); } catch { }
    }
}
