using System.Diagnostics;
using System.Windows;
using Microsoft.Win32;
using PBZModManager;

namespace PBZModManagerGui;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var g = Manager.ResolveGame(null, out var how);
            if (g != null) { GamePath.Text = g; AppendLog($"已自动检测到游戏（{how}）：{g}"); }
            else AppendLog("未自动检测到游戏，请手动选择（选中游戏的 platform\\steam 目录或其上级均可）。");

            // 若本管理器旁自带 ue4ss\（发行包布局），默认勾选「使用自带 UE4SS」并填好路径
            var bundled = AppContext.BaseDirectory;
            if (System.IO.Directory.Exists(System.IO.Path.Combine(bundled, "ue4ss")))
            {
                Ue4ssPath.Text = bundled;
                UseBundle.IsChecked = true;
                AppendLog("已检测到随包自带 UE4SS，默认使用它（也可改选你自己的）。");
            }
        };
    }

    private void AppendLog(string m)
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.Invoke(() => AppendLog(m)); return; }
        LogBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {m}\n");
        LogBox.ScrollToEnd();
    }

    private string? PickFolder()
    {
        var dlg = new OpenFolderDialog { Title = "选择目录" };
        return dlg.ShowDialog() == true ? dlg.FolderName : null;
    }

    private string? GameDirOrNull(bool quiet = false)
    {
        var g = GamePath.Text?.Trim();
        if (string.IsNullOrEmpty(g)) { if (!quiet) AppendLog("请先填写/选择游戏目录。"); return null; }
        return Manager.NormalizeToSteamDir(g);
    }

    private void AutoDetect_Click(object s, RoutedEventArgs e)
    {
        var g = Manager.ResolveGame(null, out var how);
        if (g == null) { AppendLog("没自动检测到，请手动选择。"); return; }
        GamePath.Text = g; AppendLog($"检测到（{how}）：{g}");
    }

    private void BrowseGame_Click(object s, RoutedEventArgs e)
    {
        var d = PickFolder(); if (d != null) GamePath.Text = Manager.NormalizeToSteamDir(d);
    }

    private void BrowseUe4ss_Click(object s, RoutedEventArgs e)
    {
        var d = PickFolder(); if (d != null) { Ue4ssPath.Text = d; UseBundle.IsChecked = true; }
    }

    private void Status_Click(object s, RoutedEventArgs e)
    {
        var g = GameDirOrNull(); if (g == null) return;
        AppendLog("—— 状态 ——");
        foreach (var line in Manager.StatusText(g).Split('\n')) if (line.Trim().Length > 0) AppendLog(line.TrimEnd('\r'));
    }

    private void Install_Click(object s, RoutedEventArgs e)
    {
        var g = GameDirOrNull(); if (g == null) return;
        var src = System.IO.Path.Combine(AppContext.BaseDirectory, Manager.ModName);
        string? ue = null;
        if (UseBundle.IsChecked == true)
        {
            ue = Ue4ssPath.Text?.Trim();
            if (string.IsNullOrEmpty(ue)) { AppendLog("勾选了「自带 UE4SS」但没选目录。"); return; }
        }
        bool useOwn = UseOwn.IsChecked == true;
        bool force = ForceProxy.IsChecked == true;
        var btn = (System.Windows.Controls.Button)s; btn.IsEnabled = false;
        AppendLog("== 开始安装 / 修复 ==");
        Task.Run(() =>
        {
            try { Manager.Install(g, src, ue, useOwn, force, false, AppendLog); }
            catch (Exception ex) { AppendLog("错误: " + ex.Message); }
            finally { Dispatcher.Invoke(() => btn.IsEnabled = true); }
        });
    }

    private void Uninstall_Click(object s, RoutedEventArgs e)
    {
        var g = GameDirOrNull(); if (g == null) return;
        var btn = (System.Windows.Controls.Button)s; btn.IsEnabled = false;
        AppendLog("== 开始卸载 ==");
        Task.Run(() =>
        {
            try { Manager.Uninstall(g, false, AppendLog); }
            catch (Exception ex) { AppendLog("错误: " + ex.Message); }
            finally { Dispatcher.Invoke(() => btn.IsEnabled = true); }
        });
    }

    private void OpenGameDir_Click(object s, RoutedEventArgs e)
    {
        var g = GameDirOrNull(); if (g == null) return;
        try { Process.Start("explorer.exe", g); } catch (Exception ex) { AppendLog("打开失败: " + ex.Message); }
    }
}
