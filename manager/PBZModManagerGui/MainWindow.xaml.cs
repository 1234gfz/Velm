using System.Diagnostics;
using System.Windows;
using Microsoft.Win32;
using PBZModManager;

namespace PBZModManagerGui;

public partial class MainWindow : Window
{
    private Manager.UpdateInfo? _info;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var g = Manager.ResolveGame(null, out var how);
            if (g != null) { GamePath.Text = g; AppendLog($"已自动检测到游戏（{how}）：{g}"); }
            else AppendLog("未自动检测到游戏，请手动选择（选中游戏的 platform\\steam 目录或其上级均可）。");

            var mv = Manager.LocalManagerVersion(); var pv = Manager.PayloadModVersion();
            Title = $"Velm 小维 · 安装器    管理器 v{mv} / 随包模组 v{pv}";
            AppendLog($"版本：管理器 v{mv}，随包模组 v{pv}");
            if (g != null) AppendLog("游戏内已装模组：" + Manager.InstalledModVersion(g));

            // 发行包布局：Manager\ 与 Mod\ 并列；若找到 Mod\ue4ss 就默认用自带 UE4SS
            var modRoot = Manager.FindModRoot();
            if (modRoot != null && System.IO.Directory.Exists(System.IO.Path.Combine(modRoot, "ue4ss")))
            {
                Ue4ssPath.Text = modRoot;
                UseBundle.IsChecked = true;
                AppendLog("已检测到随包自带 UE4SS（" + System.IO.Path.Combine(modRoot, "ue4ss") + "），默认使用它。");
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
        var modRoot = Manager.FindModRoot();
        var src = modRoot != null ? System.IO.Path.Combine(modRoot, Manager.ModName)
                                  : System.IO.Path.Combine(AppContext.BaseDirectory, Manager.ModName);
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

    // 「使用自带 UE4SS」与「使用我已安装的 UE4SS」互斥：勾一个自动取消另一个
    private void UseBundle_Checked(object s, RoutedEventArgs e) { if (UseOwn != null && UseOwn.IsChecked == true) UseOwn.IsChecked = false; }
    private void UseOwn_Checked(object s, RoutedEventArgs e) { if (UseBundle != null && UseBundle.IsChecked == true) UseBundle.IsChecked = false; }

    private void OpenModDir_Click(object s, RoutedEventArgs e)
    {
        var g = GameDirOrNull(); if (g == null) return;
        var p = Manager.InstalledModPath(g);
        if (System.IO.Directory.Exists(p))
        {
            try { Process.Start("explorer.exe", p); } catch (Exception ex) { AppendLog("打开失败: " + ex.Message); }
        }
        else
        {
            MessageBox.Show("还没安装，或该路径不存在：\n" + p, "打开 mod 目录", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private void Update_Click(object s, RoutedEventArgs e)
    {
        var btn = (System.Windows.Controls.Button)s; btn.IsEnabled = false;
        var proxy = ProxyBox.Text?.Trim();
        AppendLog("== 检查更新 ==");
        Task.Run(() =>
        {
            try
            {
                var info = Manager.CheckUpdates(string.IsNullOrWhiteSpace(proxy) ? null : proxy);
                _info = info;
                var lm = Manager.LocalManagerVersion(); var pm = Manager.PayloadModVersion();
                AppendLog($"管理器：本地 v{lm} / 最新 v{info.manager}");
                AppendLog($"模组：本地 v{pm} / 最新 v{info.mod}");
                bool modNew = Manager.CompareVersion(pm, info.mod) > 0;
                bool mgrNew = Manager.CompareVersion(lm, info.manager) > 0;
                if (!modNew && !mgrNew) AppendLog("已是最新。");
                if (modNew) AppendLog("有新版模组，可点「一键更新模组」。");
                if (mgrNew) AppendLog("有新版管理器，点「更新管理器」到发布页手动替换（管理器运行中无法自我覆盖）。");
                Dispatcher.Invoke(() => { UpdateModBtn.IsEnabled = modNew; MgrUpdateBtn.IsEnabled = mgrNew; });
            }
            catch (Exception ex)
            {
                AppendLog("检查更新失败: " + ex.Message);
                AppendLog("（GitHub 直连可能被墙，可填代理再试；或手动打开 https://github.com/1234gfz/Velm/releases）");
            }
            finally { Dispatcher.Invoke(() => btn.IsEnabled = true); }
        });
    }

    private void UpdateMod_Click(object s, RoutedEventArgs e)
    {
        var g = GameDirOrNull(); if (g == null) return;
        if (Manager.IsGameRunning())
        {
            MessageBox.Show("游戏正在运行，请先关闭游戏再更新模组。", "更新模组", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var btn = (System.Windows.Controls.Button)s; btn.IsEnabled = false;
        var proxy = ProxyBox.Text?.Trim();
        Task.Run(() =>
        {
            try
            {
                if (_info == null) throw new Exception("请先点「检查更新」。");
                AppendLog($"== 一键更新模组 -> v{_info.mod} ==");
                var zip = Manager.DownloadToTemp(_info.modUrl, string.IsNullOrWhiteSpace(proxy) ? null : proxy, AppendLog);
                Manager.UpdateMod(g, zip, AppendLog);
                AppendLog($"模组已更新到 v{_info.mod}。");
            }
            catch (Exception ex) { AppendLog("更新失败: " + ex.Message); }
            finally { Dispatcher.Invoke(() => btn.IsEnabled = true); }
        });
    }

    private void MgrUpdate_Click(object s, RoutedEventArgs e)
    {
        var url = (_info != null && !string.IsNullOrEmpty(_info.managerUrl)) ? _info.managerUrl : "https://github.com/1234gfz/Velm/releases";
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception ex) { AppendLog("打开失败: " + ex.Message); }
        AppendLog("请在发布页下载新版管理器，替换 Manager\\ 里的 exe/dll（管理器运行中无法自我覆盖）。");
    }
}
