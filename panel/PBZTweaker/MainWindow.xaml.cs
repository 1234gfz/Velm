using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace PBZTweaker
{
    public partial class MainWindow : Window
    {
        private static readonly string JsonPath = ResolveJsonPath();
        private static readonly string PresetPath =
            Path.Combine(Path.GetDirectoryName(JsonPath) ?? ".", "pbz_presets.json");

        private const double DesignHeight = 800;
        private const double EdgeMargin = 24;

        // 暖石墨配色（不再是蓝色系）
        private const string CText = "#B7B1A8";
        private const string CTextDim = "#7C766E";
        private const string CAccent = "#C0AF93";
        private const string CCard = "#12FFFFFF";
        private const string CFldBg = "#2B2926";
        private const string CFldFg = "#DDD8D0";

        private JsonObject _root;
        private JsonObject _presets = new JsonObject();
        private string _lastWrite = "";
        private DateTime _suppressUntil = DateTime.MinValue;
        private bool _dirty;
        private readonly DispatcherTimer _reloadTimer;
        private FileSystemWatcher _watcher;
        private int _paramCount;
        private bool _loadingPresets;
        private readonly Dictionary<string, bool> _collapsed = new Dictionary<string, bool>();


        private IntPtr _hwnd = IntPtr.Zero;
        private IntPtr _gameHwnd = IntPtr.Zero;
        private bool _interactive;
        private readonly DispatcherTimer _gameWatch;

        // 心跳定时器：每 5 秒把当前 Unix 秒写进 panel_heartbeat.txt。
        // 作用：让 Lua 知道面板还活着。没有心跳的话，Lua 只能靠「定期 start 一次」
        // 来保证面板存在，而 os.execute 在 Windows 上会闪一个黑窗口（游戏里很明显）。
        private readonly DispatcherTimer _hbTimer;
        private bool _seenGame;
        private int _missCount;

        // 托盘图标。
        // 为什么必须有：面板是 WS_EX_TOOLWINDOW 的隐藏悬浮窗，任务栏里根本不出现，
        // 启动后唯一入口是 F8 热键。一旦热键被别的程序抢走（或者用户不知道该按 F8），
        // 面板就等于「人间蒸发」——用户既看不见它，也没法关掉或呼出。
        // 有了托盘图标，随时能右键呼出/退出，也不占用任务栏。
        private System.Windows.Forms.NotifyIcon _tray;

        // 进程优先级：游戏会在启动时把自己的优先级设成 High，抢 CPU、挤占系统响应。
        // 面板只要在发现游戏的第一次把它拉回 AboveNormal 即可 —— 游戏只在启动时设一次，
        // 不需要持续轮询纠正。_priorityApplied 保证每局只做一次。
        private bool _priorityApplied;

        // 是否启用优先级锁定（对应参数表里的 pinPriority，默认 true）。
        private bool PinPriorityEnabled = true;


        private const int HOTKEY_ID = 0xB0B;
        private const int WM_HOTKEY = 0x0312;
        private const uint VK_F8 = 0x77;
        private const int GWL_EXSTYLE = -20;
        private const int WS_EX_TRANSPARENT = 0x00000020;
        private const int WS_EX_NOACTIVATE = 0x08000000;
        private const int WS_EX_TOOLWINDOW = 0x00000080;

        [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int index, int value);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

        [DllImport("user32.dll")] private static extern bool AdjustWindowRectEx(ref RECT r, int style, bool menu, int exStyle);

        private const int GWL_STYLE = -16;
        private const int WS_CAPTION = 0x00C00000;
        private const int WS_THICKFRAME = 0x00040000;
        private const int WS_SYSMENU = 0x00080000;
        private const int WS_MINIMIZEBOX = 0x00020000;
        private const int WS_MAXIMIZEBOX = 0x00010000;
        private const int WS_POPUP = unchecked((int)0x80000000);
        private const uint SWP_NOZORDER = 0x0004;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_FRAMECHANGED = 0x0020;

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left, Top, Right, Bottom; }

        private static string ResolveJsonPath()
        {
            try
            {
                var side = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "pbz_path.txt");
                if (File.Exists(side))
                {
                    var p = File.ReadAllText(side).Trim();
                    if (p.Length > 0) return p;
                }
            }
            catch { }
            return @"E:\SteamLibrary\steamapps\common\PBZ\platform\steam\ue4ss\Mods\PBZFog\pbz_tweaker.json";
        }

        public MainWindow()
        {
            InitializeComponent();

            _reloadTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            _reloadTimer.Tick += (s, e) => { _reloadTimer.Stop(); BuildUi(true); };

            LoadJson();
            if (_root != null && _root.ContainsKey("pinPriority"))
            {
                try { PinPriorityEnabled = GetBool(_root, "pinPriority", true); } catch { }
            }
            LoadPresets();
            BuildUi();
            StartWatcher();

            // 游戏退出后自己也退出（连着几次找不到 PBZ.exe 才算）
            _gameWatch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            _gameWatch.Tick += (s2, e2) => CheckGameAlive();
            _gameWatch.Start();

            _hbTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            _hbTimer.Tick += (s3, e3) => WriteHeartbeat();
            _hbTimer.Start();
            WriteHeartbeat();

            InitTrayIcon();

            var menu = new ContextMenu();
            var quit = new MenuItem { Header = "退出程序" };
            quit.Click += (s, e) =>
            {
                try { UnregisterHotKey(_hwnd, HOTKEY_ID); } catch { }
                Application.Current.Shutdown();
            };
            var reload = new MenuItem { Header = "重新读取参数表" };
            reload.Click += (s, e) => { LoadJson(); BuildUi(); };

            var resample = new MenuItem { Header = "重新采样后处理原值" };
            resample.ToolTip = "先把要重采的参数开关关掉，再点这里。下一轮打开开关时，会从游戏当前状态重新采一份原值";
            resample.Click += (s, e) =>
            {
                if (_root == null) return;
                int n = 0;
                try { n = _root["resample"]?.GetValue<int>() ?? 0; } catch { }
                _root["resample"] = JsonValue.Create(n + 1);
                if (SaveJson())
                    Status.Text = "已清空后处理原值记录 · 下次打开开关会重新采样";
            };
            menu.Items.Add(resample);
            menu.Items.Add(reload);

            // 进程优先级锁定开关（默认开）。游戏启动时会把自身设为 High，
            // 面板发现游戏后把它拉回「高于正常」。不需要持续轮询——游戏只设一次。
            var pin = new MenuItem
            {
                Header = "把游戏进程优先级锁为「高于正常」",
                IsCheckable = true,
                IsChecked = PinPriorityEnabled,
                ToolTip = "游戏启动时会把自身优先级设为 High，可能拖慢系统。勾选后面板会把游戏拉回 AboveNormal。"
            };
            pin.Click += (s, e) =>
            {
                PinPriorityEnabled = pin.IsChecked;
                if (_root != null) { _root["pinPriority"] = JsonValue.Create(PinPriorityEnabled); SaveJson(); }
                _priorityApplied = false;           // 重新生效一次
                if (PinPriorityEnabled) ApplyPriorityOnce();
            };
            menu.Items.Add(pin);

            menu.Items.Add(quit);
            Root.ContextMenu = menu;

            PresetBox.SelectionChanged += (s, e) => LoadSelectedPreset();

            MasterSwitch.Checked += (s, e) => SetMaster(true);
            MasterSwitch.Unchecked += (s, e) => SetMaster(false);
            SyncMasterUi();
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            _hwnd = new WindowInteropHelper(this).Handle;
            ApplyInteractiveStyle(false);
            var src = HwndSource.FromHwnd(_hwnd);
            src?.AddHook(WndProc);
            // 注册失败时 RegisterHotKey 返回 false，之前没检查，
            // 表现就是「按 F8 完全没反应」且日志里什么都没有。
            var hkOk = RegisterHotKey(_hwnd, HOTKEY_ID, 0, VK_F8);
            try
            {
                var logPath = System.IO.Path.Combine(
                    System.IO.Path.GetDirectoryName(JsonPath) ?? ".", "panel_hotkey.log");
                System.IO.File.AppendAllText(logPath,
                    string.Format("{0} hotkey F8 register={1} hwnd={2} err={3}\n",
                        DateTime.Now.ToString("HH:mm:ss"), hkOk, _hwnd,
                        hkOk ? 0 : System.Runtime.InteropServices.Marshal.GetLastWin32Error()));
            }
            catch { }
        }

        // ------------------------------------------------------------ 托盘图标

        // 面板是隐藏悬浮窗，任务栏看不到它。没有托盘图标的话，用户完全不知道
        // 这个程序在哪、热键失效时也没法操作。托盘图标就是它唯一的「门牌」。
        private void InitTrayIcon()
        {
            try
            {
                _tray = new System.Windows.Forms.NotifyIcon
                {
                    Text = "影之刃零 雾效调参器（F8 呼出面板）",
                    Visible = true,
                    Icon = MakeTrayIcon(),
                };

                var m = new System.Windows.Forms.ContextMenuStrip();

                var showItem = new System.Windows.Forms.ToolStripMenuItem("显示 / 隐藏面板（F8）");
                showItem.Click += (s, e) => Dispatcher.Invoke(() =>
                {
                    if (_interactive && IsVisible) HideOverlay();
                    else ShowOverlay();
                });
                m.Items.Add(showItem);

                var reloadItem = new System.Windows.Forms.ToolStripMenuItem("重新读取参数表");
                reloadItem.Click += (s, e) => Dispatcher.Invoke(() => { LoadJson(); BuildUi(); });
                m.Items.Add(reloadItem);

                m.Items.Add(new System.Windows.Forms.ToolStripSeparator());

                var exitItem = new System.Windows.Forms.ToolStripMenuItem("退出调参器");
                exitItem.Click += (s, e) => Dispatcher.Invoke(() =>
                {
                    try { UnregisterHotKey(_hwnd, HOTKEY_ID); } catch { }
                    RestoreDisplayMode();
                    Application.Current.Shutdown();
                });
                m.Items.Add(exitItem);

                _tray.ContextMenuStrip = m;
                _tray.DoubleClick += (s, e) => Dispatcher.Invoke(() =>
                {
                    if (_interactive && IsVisible) HideOverlay();
                    else ShowOverlay();
                });
            }
            catch (Exception ex)
            {
                LogStartup("托盘图标创建失败: " + ex.Message);
            }
        }

        // 程序没有 .ico 资源，就用代码画一个 16×16 的小圆点，避免依赖外部文件。
        private static System.Drawing.Icon MakeTrayIcon()
        {
            try
            {
                using var bmp = new System.Drawing.Bitmap(16, 16);
                using (var g = System.Drawing.Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    g.Clear(System.Drawing.Color.Transparent);
                    using var brush = new System.Drawing.SolidBrush(
                        System.Drawing.Color.FromArgb(255, 0xC0, 0xAF, 0x93));
                    g.FillEllipse(brush, 1, 1, 14, 14);
                    using var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(255, 0x2B, 0x29, 0x26), 1.6f);
                    g.DrawEllipse(pen, 1, 1, 14, 14);
                }
                return System.Drawing.Icon.FromHandle(bmp.GetHicon());
            }
            catch
            {
                return System.Drawing.SystemIcons.Application;
            }
        }

        // ------------------------------------------------------------ 悬浮层
        private void ApplyInteractiveStyle(bool on)
        {
            if (_hwnd == IntPtr.Zero) return;
            var ex = GetWindowLong(_hwnd, GWL_EXSTYLE);
            if (on) ex &= ~(WS_EX_NOACTIVATE | WS_EX_TRANSPARENT);
            else ex |= WS_EX_NOACTIVATE | WS_EX_TRANSPARENT;
            ex |= WS_EX_TOOLWINDOW;
            SetWindowLong(_hwnd, GWL_EXSTYLE, ex);
        }

        // 把游戏进程优先级从 High 拉回 AboveNormal（高于正常）。
        // 为什么不是 Normal：用户实测 High 会明显拖慢系统，但完全压到 Normal 又可能
        // 让游戏本身差口气；AboveNormal 是折中——比普通程序高，但不至于饿死系统。
        // 只在发现游戏的第一次调用，失败也不重试（游戏若之后自己改回来，那是它自己的事）。
        private void ApplyPriorityOnce()
        {
            _priorityApplied = true;
            if (!PinPriorityEnabled) return;
            try
            {
                foreach (var p in Process.GetProcessesByName("PBZ"))
                {
                    try
                    {
                        if (p.PriorityClass != ProcessPriorityClass.AboveNormal)
                        {
                            var before = p.PriorityClass;
                            p.PriorityClass = ProcessPriorityClass.AboveNormal;
                            LogStartup(string.Format("进程优先级 PID {0}: {1} -> AboveNormal", p.Id, before));
                        }
                    }
                    catch (Exception ex)
                    {
                        LogStartup("进程优先级 PID " + p.Id + " 设置失败: " + ex.Message);
                    }
                }
            }
            catch { }
        }

        private static void LogStartup(string line)
        {
            try
            {
                var p = System.IO.Path.Combine(
                    System.IO.Path.GetDirectoryName(JsonPath) ?? ".", "startup.log");
                System.IO.File.AppendAllText(p,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + line + "\n");
            }
            catch { }
        }

        private void CheckGameAlive()
        {
            bool alive;
            try { alive = Process.GetProcessesByName("PBZ").Length > 0; }
            catch { alive = true; }

            if (alive)
            {
                _seenGame = true; _missCount = 0;
                // 游戏启动时把自己设成 High。这里在第一次发现游戏时拉回 AboveNormal，
                // 每局只做一次（游戏只在启动时设一次优先级，无需持续纠正）。
                if (!_priorityApplied) ApplyPriorityOnce();
                return;
            }
            if (!_seenGame) return;                 // 手动单独启动时不自动退出
            if (++_missCount < 3) return;           // 约 6 秒确认一次，避免读图瞬间误杀
            _priorityApplied = false;               // 游戏退出，下一局重新生效

            try { _hbTimer?.Stop(); } catch { }
            DeleteHeartbeat();
            try { UnregisterHotKey(_hwnd, HOTKEY_ID); } catch { }
            RestoreDisplayMode();
            Application.Current.Shutdown();
        }

        private static IntPtr FindGameWindow()
        {
            try
            {
                foreach (var p in Process.GetProcessesByName("PBZ"))
                    if (p.MainWindowHandle != IntPtr.Zero) return p.MainWindowHandle;
            }
            catch { }
            return IntPtr.Zero;
        }

        private void PlaceOverGame()
        {
            if (_gameHwnd == IntPtr.Zero) _gameHwnd = FindGameWindow();
            if (_gameHwnd == IntPtr.Zero) return;

            RECT r;
            if (!GetWindowRect(_gameHwnd, out r)) return;
            if (r.Right - r.Left < 320 || r.Bottom - r.Top < 240) return;

            double sx = 1.0, sy = 1.0;
            var src = PresentationSource.FromVisual(this);
            if (src?.CompositionTarget != null)
            {
                sx = src.CompositionTarget.TransformToDevice.M11;
                sy = src.CompositionTarget.TransformToDevice.M22;
            }
            if (sx <= 0) sx = 1.0;
            if (sy <= 0) sy = 1.0;

            double gx = r.Left / sx, gy = r.Top / sy;
            double gw = (r.Right - r.Left) / sx, gh = (r.Bottom - r.Top) / sy;

            Height = Math.Max(420, Math.Min(DesignHeight, gh - 48));
            Left = gx + gw - Width - EdgeMargin;
            Top = gy + EdgeMargin;
            if (Left < gx) Left = gx;
            if (Top < gy) Top = gy;
        }

        // ------------------------------------------------------------ 独占显示模式
        // 窗口方式改不了「露桌面」这件事：任务栏本身就是 topmost，任何窗口都压不住。
        // 真正干净的做法是把显示器切到目标分辨率，多余的部分由扫描输出自己补黑边。
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType,
                       dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplaySettings(string device, int modeNum, ref DEVMODE devMode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettings(IntPtr devMode, int flags);

        private const int ENUM_CURRENT_SETTINGS = -1;
        private const int DM_PELSWIDTH = 0x00080000;
        private const int DM_PELSHEIGHT = 0x00100000;
        private const int CDS_TEST = 0x00000002;
        private const int CDS_FULLSCREEN = 0x00000004;
        private const int DISP_CHANGE_SUCCESSFUL = 0;
        private const int DISP_CHANGE_RESTART = 1;

        private bool _modeChanged;

        private static bool ReadCurrentMode(out DEVMODE dm)
        {
            dm = new DEVMODE { dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)) };
            return EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm);
        }

        // 切到指定分辨率。先 CDS_TEST 验证一遍，通过了才真切，免得把屏幕搞黑
        private bool SwitchDisplayMode(int w, int h)
        {
            DEVMODE dm;
            if (!ReadCurrentMode(out dm)) return false;

            dm.dmPelsWidth = w;
            dm.dmPelsHeight = h;
            dm.dmFields |= DM_PELSWIDTH | DM_PELSHEIGHT;
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));

            if (ChangeDisplaySettings(ref dm, CDS_TEST) != DISP_CHANGE_SUCCESSFUL) return false;

            int r = ChangeDisplaySettings(ref dm, CDS_FULLSCREEN);
            if (r != DISP_CHANGE_SUCCESSFUL && r != DISP_CHANGE_RESTART) return false;

            _modeChanged = true;
            return true;
        }

        private void RestoreDisplayMode()
        {
            if (!_modeChanged) return;
            _modeChanged = false;
            try { ChangeDisplaySettings(IntPtr.Zero, 0); } catch { }
        }

        // ------------------------------------------------------------ 分辨率（窗口尺寸）
        // 引擎的 ApplyResolutionSettings 在这游戏里被架空了：调用返回成功、属性也改了，
        // 但窗口纹丝不动。所以直接改窗口尺寸，UE 收到 WM_SIZE 会自行重建 swapchain。
        private void ApplyResolution(string spec)
        {
            if (string.IsNullOrEmpty(spec)) return;

            _gameHwnd = FindGameWindow();
            if (_gameHwnd == IntPtr.Zero) { Status.Text = "找不到游戏窗口，分辨率没改"; return; }

            if (spec == "none")
            {
                RestoreDisplayMode();
                Status.Text = "分辨率：不修改";
                return;
            }

            var halves = spec.Split(':');
            if (halves.Length != 2) return;
            var wh = halves[0].Split('x');
            int w, h;
            if (wh.Length != 2 || !int.TryParse(wh[0], out w) || !int.TryParse(wh[1], out h)) return;
            char mode = halves[1][0];

            if (mode == 'D')
            {
                // 已经是这个分辨率就别再切一次，省得每次点应用都黑屏闪
                DEVMODE cur;
                bool same = ReadCurrentMode(out cur) && cur.dmPelsWidth == w && cur.dmPelsHeight == h;
                if (!same && !SwitchDisplayMode(w, h))
                {
                    Status.Text = string.Format("驱动不支持 {0}×{1} 这个模式", w, h);
                    return;
                }
                // 分辨率已经变了，窗口按新的「屏幕」铺满，桌面和任务栏自然就不见了
                int nw = GetSystemMetrics(0), nh = GetSystemMetrics(1);
                int ds = GetWindowLong(_gameHwnd, GWL_STYLE);
                ds &= ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
                ds |= WS_POPUP;
                SetWindowLong(_gameHwnd, GWL_STYLE, ds);
                SetWindowPos(_gameHwnd, IntPtr.Zero, 0, 0, nw, nh, SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
                Status.Text = string.Format("已切到 {0}×{1} · 退出面板会自动还原", w, h);
                return;
            }

            // 普通窗口模式：桌面分辨率先还原回原样
            RestoreDisplayMode();

            int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);

            int style = GetWindowLong(_gameHwnd, GWL_STYLE);
            if (mode == 'B')
            {
                style &= ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
                style |= WS_POPUP;
            }
            else
            {
                style &= ~WS_POPUP;
                style |= WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
            }
            SetWindowLong(_gameHwnd, GWL_STYLE, style);

            int aw = w, ah = h;
            if (mode != 'B')
            {
                var rc = new RECT { Left = 0, Top = 0, Right = w, Bottom = h };
                if (AdjustWindowRectEx(ref rc, style, false, GetWindowLong(_gameHwnd, GWL_EXSTYLE)))
                {
                    aw = rc.Right - rc.Left;
                    ah = rc.Bottom - rc.Top;
                }
            }

            int x = Math.Max(0, (sw - aw) / 2);
            int y = Math.Max(0, (sh - ah) / 2);
            SetWindowPos(_gameHwnd, IntPtr.Zero, x, y, aw, ah, SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
            Status.Text = string.Format("分辨率 {0}×{1}", w, h);
        }

        private void ApplyAppParams()
        {
            if (_root?["groups"] is not JsonArray groups) return;
            if (!MasterOn()) return;        // 总开关关着就什么都不下发
            foreach (var g in groups)
            {
                if (g?["parameters"] is not JsonArray ps) continue;
                foreach (var p in ps)
                {
                    if (p is not JsonObject po) continue;
                    if ((string)po["handler"] != "app") continue;
                    if (!GetBool(po, "enabled", false)) continue;
                    var spec = po["value"]?.GetValue<string>() ?? "";
                    ApplyResolution(spec);
                }
            }
        }

        private void ShowOverlay()
        {
            _gameHwnd = FindGameWindow();
            PlaceOverGame();
            Show();
            Topmost = true;
            ApplyInteractiveStyle(true);
            try { Activate(); SetForegroundWindow(_hwnd); Focus(); } catch { }
            _interactive = true;
            SubText.Text = "F8 收起并交还鼠标 · 拖动标题可移动";
        }

        private void HideOverlay()
        {
            _interactive = false;
            Hide();
            ApplyInteractiveStyle(false);
            if (_gameHwnd == IntPtr.Zero) _gameHwnd = FindGameWindow();
            if (_gameHwnd != IntPtr.Zero) { try { SetForegroundWindow(_gameHwnd); } catch { } }
            SubText.Text = "F8 呼出面板";
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == WM_HOTKEY && wParam.ToInt32() == HOTKEY_ID)
            {
                if (_interactive && IsVisible) HideOverlay();
                else ShowOverlay();
                handled = true;
            }
            return IntPtr.Zero;
        }

        // ------------------------------------------------------------ 文件
        private void StartWatcher()
        {
            try
            {
                var dir = Path.GetDirectoryName(JsonPath);
                if (dir == null || !Directory.Exists(dir)) return;
                _watcher = new FileSystemWatcher(dir, Path.GetFileName(JsonPath))
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName
                };
                _watcher.Changed += (s, e) => OnExternalChange();
                _watcher.Created += (s, e) => OnExternalChange();
                _watcher.Renamed += (s, e) => OnExternalChange();
                _watcher.EnableRaisingEvents = true;
            }
            catch { }
        }

        private void OnExternalChange()
        {
            if (DateTime.UtcNow < _suppressUntil) return;
            if (_dirty) return;                       // 有未应用的改动，别把面板冲掉
            string text;
            try { text = File.ReadAllText(JsonPath); } catch { return; }
            if (text == _lastWrite) return;
            Dispatcher.BeginInvoke(new Action(() => { _reloadTimer.Stop(); _reloadTimer.Start(); }));
        }

        private void LoadJson()
        {
            try
            {
                var text = File.ReadAllText(JsonPath);
                _root = JsonNode.Parse(text) as JsonObject;
                if (_root == null) throw new Exception("根节点不是对象");
            }
            catch (Exception ex)
            {
                Status.Text = "参数表读取失败: " + ex.Message;
                _root = null;
            }
        }

        private void LoadPresets()
        {
            try
            {
                if (File.Exists(PresetPath))
                    _presets = JsonNode.Parse(File.ReadAllText(PresetPath)) as JsonObject ?? new JsonObject();
                else
                    _presets = new JsonObject();
            }
            catch { _presets = new JsonObject(); }

            _loadingPresets = true;
            PresetBox.Items.Clear();
            foreach (var kv in _presets)
                PresetBox.Items.Add(kv.Key);
            _loadingPresets = false;
        }

        private void SavePresets()
        {
            try
            {
                File.WriteAllText(PresetPath,
                    _presets.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }

        // ------------------------------------------------------------ 总开关
        private bool _masterReady;

        private bool MasterOn()
        {
            if (_root == null) return true;
            return GetBool(_root, "master", true);
        }

        private void SyncMasterUi()
        {
            bool on = MasterOn();
            _masterReady = false;
            if (MasterSwitch != null) MasterSwitch.IsChecked = on;
            _masterReady = true;
            ApplyMasterVisual(on);
        }

        private void ApplyMasterVisual(bool on)
        {
            if (Panel != null) Panel.Opacity = on ? 1.0 : 0.45;
            if (MasterLabel != null) MasterLabel.Foreground = Brush(on ? CAccent : CTextDim);
        }

        // 总开关立即生效，不跟其它参数一起等「应用」——这是个“马上回到原版”的开关
        private void SetMaster(bool on)
        {
            if (!_masterReady || _root == null) return;
            _root["master"] = JsonValue.Create(on);
            ApplyMasterVisual(on);
            if (SaveJson())
            {
                _dirty = false;
                ApplyBtn.Content = "应用";
                Status.Text = on ? "整体效果已开启" : "整体效果已关闭 · 全部回到游戏原版（数值都留着）";
                if (on) { ApplyAppParams(); TakeFocusBack(); } else RestoreDisplayMode();
            }
        }

        private void MarkDirty()
        {
            _dirty = true;
            ApplyBtn.Content = "应用 •";
            Status.Text = "有未应用的改动";
        }

        private void Apply_Click(object sender, RoutedEventArgs e)
        {
            if (SaveJson())
            {
                _dirty = false;
                ApplyBtn.Content = "应用";
                Status.Text = "已应用 " + DateTime.Now.ToString("HH:mm:ss") + " · " + _paramCount + " 项";
                ApplyAppParams();
                TakeFocusBack();
                // 切完显示模式后系统会自己再挪一次前台，补一枪
                var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
                t.Tick += (s2, e2) => { t.Stop(); TakeFocusBack(); };
                t.Start();
            }
        }

        // 应用分辨率/显示模式会把前台拽到游戏那边，鼠标一动镜头就跟着转。
        // 这里把焦点抢回面板，并且延迟再抢一次（切完显示模式系统会自己挪一次前台）。
        private void TakeFocusBack()
        {
            if (!IsVisible) return;
            try { Activate(); SetForegroundWindow(_hwnd); } catch { }
        }

        private void Revert_Click(object sender, RoutedEventArgs e)
        {
            _dirty = false;
            ApplyBtn.Content = "应用";
            LoadJson();
            BuildUi();
        }

        private bool SaveJson()
        {
            if (_root == null) return false;
            try
            {
                var text = _root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
                if (text == _lastWrite) return true;
                _suppressUntil = DateTime.UtcNow.AddMilliseconds(700);
                File.WriteAllText(JsonPath, text);
                _lastWrite = text;
                return true;
            }
            catch (Exception ex)
            {
                Status.Text = "保存失败: " + ex.Message;
                return false;
            }
        }

        // ------------------------------------------------------------ 预设
        private void LoadSelectedPreset()
        {
            if (_loadingPresets || _root == null) return;
            var name = PresetBox.SelectedItem as string;
            if (string.IsNullOrWhiteSpace(name)) return;
            if (_presets[name] is not JsonObject preset) return;

            OverwriteFromPreset(name, preset, true);
        }

        private void OverwriteFromPreset(string name, JsonObject preset, bool applyNow)
        {
            foreach (var kv in preset)
            {
                var node = FindParam(kv.Key);
                if (node != null && kv.Value != null) node["value"] = kv.Value.DeepClone();
            }
            BuildUi();

            if (applyNow)
            {
                if (SaveJson())
                {
                    _dirty = false;
                    ApplyBtn.Content = "应用";
                    Status.Text = "已用预设「" + name + "」覆盖并应用";
                }
            }
            else
            {
                MarkDirty();
                Status.Text = "已载入预设「" + name + "」，点应用生效";
            }
        }

        private void PresetApply_Click(object sender, RoutedEventArgs e)
        {
            var name = PresetBox.SelectedItem as string;
            if (string.IsNullOrEmpty(name) || _presets[name] is not JsonObject preset)
            {
                Status.Text = "先选中一个预设";
                return;
            }
            OverwriteFromPreset(name, preset, true);
        }

        private JsonObject FindParam(string key)
        {
            if (_root?["groups"] is not JsonArray groups) return null;
            foreach (var g in groups)
            {
                if (g?["parameters"] is not JsonArray ps) continue;
                foreach (var p in ps)
                    if (p is JsonObject po && (string)po["key"] == key) return po;
            }
            return null;
        }

        private void PresetSave_Click(object sender, RoutedEventArgs e)
        {
            var name = (PresetName.Text ?? "").Trim();
            if (name.Length == 0) { Status.Text = "先在右边输入一个预设名字"; return; }
            if (_root?["groups"] is not JsonArray groups) return;

            var obj = new JsonObject();
            foreach (var g in groups)
            {
                if (g?["parameters"] is not JsonArray ps) continue;
                foreach (var p in ps)
                    if (p is JsonObject po && po["key"] is JsonValue kv && po["value"] != null)
                        obj[(string)kv] = po["value"].DeepClone();
            }
            _presets[name] = obj;
            SavePresets();

            _loadingPresets = true;
            if (!PresetBox.Items.Contains(name)) PresetBox.Items.Add(name);
            PresetBox.SelectedItem = name;
            PresetName.Text = "";
            _loadingPresets = false;

            Status.Text = "预设「" + name + "」已保存";
        }

        private void PresetDel_Click(object sender, RoutedEventArgs e)
        {
            var name = PresetBox.SelectedItem as string;
            if (string.IsNullOrEmpty(name) || _presets[name] == null) { Status.Text = "没选中可删的预设"; return; }
            _presets.Remove(name);
            SavePresets();
            _loadingPresets = true;
            PresetBox.Items.Remove(name);
            PresetName.Text = "";
            _loadingPresets = false;
            Status.Text = "预设「" + name + "」已删除";
        }

        // ------------------------------------------------------------ UI
        private void BuildUi(bool reloadFromDisk = false)
        {
            Panel.Children.Clear();
            if (reloadFromDisk || _root == null) LoadJson();
            if (_root == null) return;

            TitleText.Text = _root["title"]?.GetValue<string>() ?? "影之刃零 · 调参器";

            _paramCount = 0;
            if (_root["groups"] is not JsonArray groups) { Status.Text = "参数表里没有 groups"; return; }

            foreach (var gnode in groups)
            {
                if (gnode is not JsonObject g) continue;
                var name = g["name"]?.GetValue<string>() ?? "未命名";
                var desc = g["desc"]?.GetValue<string>();

                Panel.Children.Add(new TextBlock
                {
                    Text = name,
                    Foreground = Brush("#9E9890"),
                    FontSize = 19,
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(0, 18, 0, 3)
                });

                if (!string.IsNullOrEmpty(desc))
                {
                    Panel.Children.Add(new TextBlock
                    {
                        Text = desc,
                        Foreground = Brush(CTextDim),
                        FontSize = 17,
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Thickness(0, 0, 0, 5)
                    });
                }

                if (g["parameters"] is not JsonArray ps) continue;
                string lastSub = null;
                StackPanel subHost = null;
                foreach (var pnode in ps)
                {
                    if (pnode is not JsonObject p) continue;
                    var sub = p["sub"]?.GetValue<string>() ?? "";
                    if (sub != lastSub)
                    {
                        lastSub = sub;
                        subHost = null;
                        if (sub.Length > 0)
                        {
                            int cnt = 0;
                            foreach (var q in ps)
                                if (q is JsonObject qo && ((qo["sub"]?.GetValue<string>()) ?? "") == sub) cnt++;
                            subHost = new StackPanel();
                            Panel.Children.Add(MakeSubHeader(sub, cnt, subHost));
                            Panel.Children.Add(subHost);
                        }
                    }
                    var row = BuildRow(p);
                    if (subHost != null) subHost.Children.Add(row);
                    else Panel.Children.Add(row);
                    _paramCount++;
                }
            }

            if (!_dirty) Status.Text = "就绪 · " + _paramCount + " 项";
            SyncMasterUi();
        }

        // 二级折叠标题：点一下收起/展开这一小节的参数
        private Border MakeSubHeader(string name, int count, StackPanel target)
        {
            bool collapsed = !_collapsed.TryGetValue(name, out var c) || c;   // 没记录过 = 默认收起
            var tb = new TextBlock
            {
                Text = (collapsed ? "▸  " : "▾  ") + name + "   " + count,
                Foreground = Brush(CTextDim),
                FontSize = 16.5,
                VerticalAlignment = VerticalAlignment.Center
            };
            var b = new Border
            {
                Padding = new Thickness(4, 6, 4, 6),
                Margin = new Thickness(0, 9, 0, 2),
                Background = Brushes.Transparent,
                Cursor = Cursors.Hand,
                Child = tb,
                ToolTip = "点一下收起 / 展开这一组"
            };
            target.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
            b.MouseLeftButtonDown += (s2, e2) =>
            {
                bool cur = !_collapsed.TryGetValue(name, out var v) || v;
                bool now = !cur;
                _collapsed[name] = now;
                tb.Text = (now ? "▸  " : "▾  ") + name + "   " + count;
                target.Visibility = now ? Visibility.Collapsed : Visibility.Visible;
                e2.Handled = true;
            };
            return b;
        }

        private Border BuildRow(JsonObject p)
        {
            var type = p["type"]?.GetValue<string>() ?? "float";
            var label = p["label"]?.GetValue<string>() ?? p["key"]?.GetValue<string>() ?? "?";
            var hint = p["hint"]?.GetValue<string>();
            bool on = GetBool(p, "enabled", false);

            var wrap = new Border
            {
                Margin = new Thickness(0, 3, 0, 3),
                Padding = new Thickness(9, 7, 11, 7),
                CornerRadius = new CornerRadius(9),
                Background = Brush(on ? CCard : "#08FFFFFF"),
                ToolTip = string.IsNullOrEmpty(hint) ? null : hint
            };

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            // ---- 左侧：覆盖开关 + 名称
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var sw = new ToggleButton
            {
                IsChecked = on,
                Style = (Style)FindResource("SoftSwitch"),
                Margin = new Thickness(0, 0, 10, 0)
            };
            Grid.SetColumn(sw, 0);
            head.Children.Add(sw);

            var lbl = new TextBlock
            {
                Text = label,
                Foreground = Brush(on ? CText : CTextDim),
                FontSize = 19,
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap
            };
            Grid.SetColumn(lbl, 1);
            head.Children.Add(lbl);

            Grid.SetColumn(head, 0);
            grid.Children.Add(head);

            // ---- 右侧：可调节区 / 未覆盖时的只读提示
            var host = new Grid();
            Grid.SetColumn(host, 1);
            grid.Children.Add(host);

            var ctrlHost = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            var offText = new TextBlock
            {
                Foreground = Brush(CTextDim),
                FontSize = 17,
                VerticalAlignment = VerticalAlignment.Center,
                TextAlignment = TextAlignment.Right,
                Visibility = Visibility.Collapsed
            };
            host.Children.Add(ctrlHost);
            host.Children.Add(offText);

            string defText = "";

            if (type == "color")
            {
                // 颜色型参数：value 是 [R,G,B] 增益数组（1.0 = 不染色）。
                // 界面用一个色块 + 点击展开的三个滑块，不占地方。
                // 色块的显示色按「增益→亮度」映射：1.0 显示为中灰，这样能看出偏向。
                double cmin = GetDouble(p, "min", 0);
                double cmax = GetDouble(p, "max", 2);
                double cstep = GetDouble(p, "step", 0.01);

                double[] GetRGB()
                {
                    var arr = new double[] { 1, 1, 1 };
                    if (p["value"] is JsonArray ja && ja.Count >= 3)
                        for (int i = 0; i < 3; i++)
                            try { arr[i] = ja[i]!.GetValue<double>(); } catch { }
                    return arr;
                }
                void SetRGB(double[] v)
                {
                    p["value"] = new JsonArray(
                        JsonValue.Create(Math.Round(v[0], 3)),
                        JsonValue.Create(Math.Round(v[1], 3)),
                        JsonValue.Create(Math.Round(v[2], 3)));
                    MarkDirty();
                }
                static byte MapByte(double g)
                {
                    var x = Math.Clamp(g / 2.0, 0, 1);
                    return (byte)Math.Round(x * 255);
                }

                var holder = new StackPanel { Orientation = Orientation.Vertical, Width = 230 };
                var swatch = new Border
                {
                    Height = 26, CornerRadius = new CornerRadius(6),
                    Cursor = Cursors.Hand, Margin = new Thickness(0, 0, 0, 0),
                    ToolTip = "点一下展开 / 收起 RGB 滑块"
                };
                var valText = new TextBlock
                {
                    FontSize = 12, Foreground = Brush(CTextDim),
                    Margin = new Thickness(0, 3, 0, 0), HorizontalAlignment = HorizontalAlignment.Center
                };

                // 三个滑块，默认收起
                var sliders = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 6, 0, 0) };
                var sliderRefs = new Slider[3];
                var boxRefs = new TextBox[3];
                string[] names = { "R", "G", "B" };

                void RefreshSwatch()
                {
                    var c = GetRGB();
                    swatch.Background = new SolidColorBrush(Color.FromRgb(
                        MapByte(c[0]), MapByte(c[1]), MapByte(c[2])));
                    valText.Text = string.Format("{0:F2}  {1:F2}  {2:F2}", c[0], c[1], c[2]);
                }

                for (int i = 0; i < 3; ++i)
                {
                    int idx = i;
                    var line = new Grid { Margin = new Thickness(0, 1, 0, 1) };
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });

                    var lb = new TextBlock
                    {
                        Text = names[i], FontSize = 12, Foreground = Brush(CTextDim),
                        VerticalAlignment = VerticalAlignment.Center
                    };
                    Grid.SetColumn(lb, 0); line.Children.Add(lb);

                    var sl = new Slider
                    {
                        Minimum = cmin, Maximum = cmax, SmallChange = cstep,
                        LargeChange = cstep * 10, Style = (Style)FindResource("SoftSlider"),
                        Value = Math.Clamp(GetRGB()[i], cmin, cmax),
                        VerticalAlignment = VerticalAlignment.Center
                    };
                    Grid.SetColumn(sl, 1); line.Children.Add(sl);
                    sliderRefs[i] = sl;

                    var bx = new TextBox
                    {
                        Text = Fmt(GetRGB()[i], cstep), FontSize = 12,
                        Background = Brushes.Transparent, BorderThickness = new Thickness(0),
                        Foreground = Brush(CTextDim), TextAlignment = TextAlignment.Right,
                        VerticalAlignment = VerticalAlignment.Center
                    };
                    Grid.SetColumn(bx, 2); line.Children.Add(bx);
                    boxRefs[i] = bx;

                    sl.ValueChanged += (s3, e3) =>
                    {
                        var cur = GetRGB();
                        cur[idx] = sl.Value;
                        SetRGB(cur);
                        bx.Text = Fmt(sl.Value, cstep);
                        RefreshSwatch();
                    };
                    bx.LostFocus += (s3, e3) =>
                    {
                        double v;
                        if (double.TryParse(bx.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out v))
                        {
                            v = Math.Clamp(v, cmin, cmax);
                            var cur = GetRGB();
                            cur[idx] = v;
                            SetRGB(cur);
                            sl.Value = v;
                            RefreshSwatch();
                        }
                        else bx.Text = Fmt(GetRGB()[idx], cstep);
                    };

                    sliders.Children.Add(line);
                }

                swatch.MouseLeftButtonDown += (s3, e3) =>
                {
                    bool show = sliders.Visibility != Visibility.Visible;
                    sliders.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
                    if (show)
                    {
                        var c = GetRGB();
                        for (int i = 0; i < 3; i++) { sliderRefs[i].Value = c[i]; boxRefs[i].Text = Fmt(c[i], cstep); }
                    }
                    e3.Handled = true;
                };

                RefreshSwatch();
                holder.Children.Add(swatch);
                holder.Children.Add(valText);
                holder.Children.Add(sliders);
                ctrlHost.Children.Add(holder);
                defText = "1.00 1.00 1.00";
            }
            else if (type == "float")
            {
                // ---- 三模式：绝对 / 比例 / 偏移 ----
                // 参数表用 modes 声明支持哪几种（abs/ratio/offset），mode 是当前选中的。
                // 两种以上时在数值左边显示一个图标按钮（= / % / ±），点开弹菜单切换，
                // 不额外占一行 —— 每个参数多一行太浪费纵向空间。
                var modes = new List<string>();
                if (p["modes"] is JsonArray ma)
                {
                    foreach (var mn in ma)
                    {
                        try { var s2 = mn.GetValue<string>(); if (!string.IsNullOrEmpty(s2)) modes.Add(s2); }
                        catch { }
                    }
                }
                if (modes.Count == 0) modes.Add("abs");
                string curMode = "abs";
                try { curMode = p["mode"]?.GetValue<string>() ?? "abs"; } catch { }
                if (!modes.Contains(curMode)) curMode = "abs";

                // display == "percent" 的参数，界面上一律按百分比显示与输入，内部仍存 0~1 的小数
                bool pct = (p["display"]?.GetValue<string>() ?? "") == "percent";
                // uiScale：界面值 = 存储值 × k。percent 等价于 k=100，米→厘米等价于 k=0.01
                double k = 1.0;
                if (p["uiScale"] is JsonNode us)
                {
                    try { k = us.GetValue<double>(); } catch { k = 1.0; }
                }
                else if (pct) k = 100.0;
                if (k == 0) k = 1.0;
                var suffix = p["suffix"]?.GetValue<string>() ?? (pct ? "%" : null);

                double absMinS = GetDouble(p, "min", 0);
                double absMaxS = GetDouble(p, "max", 1);
                double absStepS = GetDouble(p, "step", 0.01);
                double span = Math.Max(Math.Abs(absMaxS - absMinS), 1e-6);

                // 参数表可用 "decimals": N 显式指定显示/输入的小数位数（-1 = 按 step 推断）。
                // 有些参数值域很窄但需要极细的调整（天光漏光 0~1 要调到 0.0005），
                // 只靠 step 推断会被截成两位，输入第三位就被抹掉。
                int dec = -1;
                if (p["decimals"] is JsonNode dn)
                {
                    try { dec = dn.GetValue<int>(); } catch { dec = -1; }
                }

                // 数值控件容器：切换模式时整体重建（滑条范围/步长/单位都不一样）
                var valueHost = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    VerticalAlignment = VerticalAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Right
                };

                void BuildValueControls()
                {
                    valueHost.Children.Clear();
                    double lo, hi, st, cur, def;
                    int dc;
                    string sfx;
                    if (curMode == "ratio")
                    {
                        // 比例：0~300%，100% = 保持原值。范围固定，与参数自身量纲无关。
                        lo = 0; hi = 300; st = 1; dc = 0; sfx = "%";
                        cur = GetDouble(p, "ratio", 100);
                        def = 100;
                    }
                    else if (curMode == "offset")
                    {
                        // 偏移：原值 + Δ。Δ 的范围取该参数自身跨度（例如 -2~4 就是 -6~+6），
                        // 显示时同样乘 k，和绝对模式共用单位。
                        lo = -span * k; hi = span * k;
                        st = Math.Max(absStepS * k, 1e-6); dc = dec; sfx = null;
                        cur = GetDouble(p, "offset", 0) * k;
                        def = 0;
                    }
                    else
                    {
                        lo = absMinS * k; hi = absMaxS * k;
                        st = Math.Max(absStepS * k, 1e-6); dc = dec; sfx = suffix;
                        cur = GetDouble(p, "value", absMinS) * k;
                        def = GetDouble(p, "default", absMinS) * k;
                    }
                    if (hi < lo) { var t2 = lo; lo = hi; hi = t2; }
                    if (st <= 0) st = 1;
                    cur = Math.Clamp(cur, lo, hi);

                    var slider = new Slider
                    {
                        Minimum = lo,
                        Maximum = hi,
                        Value = cur,
                        Width = 132,
                        SmallChange = st,
                        LargeChange = st * 5,
                        TickFrequency = st,
                        IsSnapToTickEnabled = st > 0,
                        VerticalAlignment = VerticalAlignment.Center,
                        IsMoveToPointEnabled = true,
                        Style = (Style)FindResource("SoftSlider")
                    };

                    var box = new TextBox
                    {
                        Text = Fmt(cur, st, dc),
                        Width = (k != 1.0 || curMode != "abs") ? 74 : 92,
                        Height = 36,
                        Margin = new Thickness(8, 0, 0, 0),
                        Padding = new Thickness(6, 3, 6, 3),
                        TextAlignment = TextAlignment.Right,
                        Background = Brush(CFldBg),
                        Foreground = Brush(CFldFg),
                        BorderBrush = Brush("#33FFFFFF"),
                        BorderThickness = new Thickness(1),
                        CaretBrush = Brush(CFldFg),
                        FontSize = 18,
                        VerticalContentAlignment = VerticalAlignment.Center
                    };

                    bool syncing = false;

                    // 写入对应的字段：绝对写 value，比例写 ratio，偏移写 offset。
                    // 三者各存各的，切换模式不丢值。
                    void Store(double shown)
                    {
                        if (curMode == "ratio") p["ratio"] = JsonValue.Create(Math.Round(shown, 4));
                        else if (curMode == "offset") p["offset"] = JsonValue.Create(Math.Round(shown / k, 6));
                        else p["value"] = JsonValue.Create(Math.Round(shown / k, 6));
                        MarkDirty();
                    }

                    double Load()
                    {
                        if (curMode == "ratio") return GetDouble(p, "ratio", 100);
                        if (curMode == "offset") return GetDouble(p, "offset", 0) * k;
                        return GetDouble(p, "value", absMinS) * k;
                    }

                    void Push(double v)
                    {
                        v = Math.Clamp(v, lo, hi);
                        syncing = true;
                        slider.Value = v;
                        syncing = false;
                        box.Text = Fmt(v, st, dc);
                        Store(v);
                    }

                    double ParseBox()
                    {
                        var txt = (box.Text ?? "").Replace("%", "").Trim();
                        double v;
                        if (double.TryParse(txt, NumberStyles.Float, CultureInfo.InvariantCulture, out v)
                            || double.TryParse(txt, NumberStyles.Float, CultureInfo.CurrentCulture, out v))
                            return v;
                        return double.NaN;
                    }

                    void Commit()
                    {
                        var v = ParseBox();
                        if (double.IsNaN(v)) { box.Text = Fmt(Load(), st, dc); return; }
                        Push(v);
                    }

                    void Reset() => Push(def);

                    slider.ValueChanged += (s, e) =>
                    {
                        if (syncing) return;
                        box.Text = Fmt(slider.Value, st, dc);
                        Store(slider.Value);
                    };

                    box.LostFocus += (s, e) => Commit();
                    box.KeyDown += (s, e) =>
                    {
                        if (e.Key == Key.Enter) { Commit(); Keyboard.ClearFocus(); e.Handled = true; }
                        else if (e.Key == Key.Escape)
                        {
                            box.Text = Fmt(Load(), st, dc);
                            Keyboard.ClearFocus(); e.Handled = true;
                        }
                    };
                    box.PreviewMouseWheel += (s, e) =>
                    {
                        Push(Load() + (e.Delta > 0 ? st : -st));
                        e.Handled = true;
                    };

                    lbl.MouseLeftButtonDown += (s, e) =>
                    {
                        if (e.ClickCount == 2) { Reset(); e.Handled = true; }
                    };

                    valueHost.Children.Add(slider);
                    valueHost.Children.Add(box);
                    if (!string.IsNullOrEmpty(sfx))
                    {
                        valueHost.Children.Add(new TextBlock
                        {
                            Text = sfx,
                            Foreground = Brush(CTextDim),
                            FontSize = 17,
                            VerticalAlignment = VerticalAlignment.Center,
                            Margin = new Thickness(4, 0, 0, 0)
                        });
                    }
                    valueHost.Children.Add(MakeResetButton(Reset));

                    // 「原版 xxx」提示随模式变：比例的原版是 100%，偏移的原版是 0。
                    defText = (curMode == "ratio")
                        ? "100%"
                        : (curMode == "offset" ? "0" : Fmt(GetDouble(p, "default", absMinS) * k, st, dc) + (suffix ?? ""));
                    offText.Text = "原版 " + defText;
                }

                BuildValueControls();

                // 模式切换按钮（只有一种模式时不显示，保持界面干净）
                if (modes.Count > 1)
                {
                    var modeBtn = new Button
                    {
                        Content = ModeIcon(curMode),
                        Width = 34,
                        Height = 36,
                        Margin = new Thickness(0, 0, 6, 0),
                        Padding = new Thickness(0),
                        FontSize = 17,
                        FontWeight = FontWeights.SemiBold,
                        Background = Brush(curMode == "abs" ? CFldBg : CAccent),
                        Foreground = Brush(curMode == "abs" ? CTextDim : "#FF1A1D24"),
                        BorderBrush = Brush("#33FFFFFF"),
                        BorderThickness = new Thickness(1),
                        Cursor = Cursors.Hand,
                        ToolTip = "切换这个参数的写法：绝对 / 比例（原值 × %） / 偏移（原值 + Δ）"
                    };
                    modeBtn.Click += (s, e) =>
                    {
                        var menu = new ContextMenu
                        {
                            PlacementTarget = modeBtn,
                            Placement = PlacementMode.Bottom
                        };
                        foreach (var m in modes)
                        {
                            var mi = new MenuItem
                            {
                                Header = (m == curMode ? "✓  " : "     ") + ModeLabel(m),
                                IsEnabled = true,
                                FontSize = 16
                            };
                            var captured = m;
                            mi.Click += (s2, e2) =>
                            {
                                if (curMode == captured) return;
                                curMode = captured;
                                p["mode"] = JsonValue.Create(captured);
                                modeBtn.Content = ModeIcon(captured);
                                modeBtn.Background = Brush(captured == "abs" ? CFldBg : CAccent);
                                modeBtn.Foreground = Brush(captured == "abs" ? CTextDim : "#FF1A1D24");
                                BuildValueControls();
                                MarkDirty();
                            };
                            menu.Items.Add(mi);
                        }
                        menu.IsOpen = true;
                        e.Handled = true;
                    };
                    ctrlHost.Children.Add(modeBtn);
                }
                ctrlHost.Children.Add(valueHost);
            }
            else if (type == "bool")
            {
                bool val = GetBool(p, "value", false);
                var btn = new ToggleButton
                {
                    Content = val ? "开" : "关",
                    IsChecked = val,
                    Width = 64,
                    Height = 32,
                    Foreground = Brush("#FF1A1D24"),
                    Background = Brush(val ? CAccent : "#3F3B36"),
                    BorderThickness = new Thickness(0),
                    FontSize = 17
                };
                btn.Checked += (s, e) =>
                {
                    btn.Content = "开";
                    btn.Background = Brush(CAccent);
                    p["value"] = JsonValue.Create(true);
                    MarkDirty();
                };
                btn.Unchecked += (s, e) =>
                {
                    btn.Content = "关";
                    btn.Background = Brush("#3F3B36");
                    p["value"] = JsonValue.Create(false);
                    MarkDirty();
                };

                void ResetBool() => btn.IsChecked = GetBool(p, "default", false);
                defText = GetBool(p, "default", false) ? "开" : "关";

                lbl.MouseLeftButtonDown += (s, e) =>
                {
                    if (e.ClickCount == 2) { ResetBool(); e.Handled = true; }
                };
                ctrlHost.Children.Add(btn);
                ctrlHost.Children.Add(MakeResetButton(ResetBool));
            }
            else if (type == "choice")
            {
                var combo = new ComboBox
                {
                    Height = 36,
                    MinWidth = 210,
                    Background = Brush(CFldBg),
                    Foreground = Brush(CFldFg),
                    BorderBrush = Brush("#33FFFFFF"),
                    BorderThickness = new Thickness(1),
                    FontSize = 18
                };

                var values = new List<string>();
                var labels = new List<string>();
                if (p["options"] is JsonArray opts)
                {
                    foreach (var o in opts)
                    {
                        if (o is not JsonObject oo) continue;
                        labels.Add(oo["label"]?.GetValue<string>() ?? "");
                        values.Add(oo["value"]?.GetValue<string>() ?? "");
                        combo.Items.Add(oo["label"]?.GetValue<string>() ?? "");
                    }
                }

                var cur = p["value"]?.GetValue<string>() ?? "";
                var idx = values.IndexOf(cur);
                combo.SelectedIndex = idx >= 0 ? idx : 0;

                combo.SelectionChanged += (s, e) =>
                {
                    var i = combo.SelectedIndex;
                    if (i < 0 || i >= values.Count) return;
                    p["value"] = JsonValue.Create(values[i]);
                    MarkDirty();
                };

                void ResetChoice()
                {
                    var d = p["default"]?.GetValue<string>() ?? cur;
                    var di = values.IndexOf(d);
                    combo.SelectedIndex = di >= 0 ? di : 0;
                }
                {
                    var d = p["default"]?.GetValue<string>() ?? cur;
                    var di = values.IndexOf(d);
                    defText = (di >= 0 && di < labels.Count) ? labels[di] : d;
                }

                lbl.MouseLeftButtonDown += (s, e) =>
                {
                    if (e.ClickCount == 2) { ResetChoice(); e.Handled = true; }
                };

                ctrlHost.Children.Add(combo);
            }

            offText.Text = "原版 " + defText;

            void ApplyEnabledVisual(bool v)
            {
                ctrlHost.Visibility = v ? Visibility.Visible : Visibility.Collapsed;
                offText.Visibility = v ? Visibility.Collapsed : Visibility.Visible;
                lbl.Foreground = Brush(v ? CText : CTextDim);
                wrap.Background = Brush(v ? CCard : "#08FFFFFF");
            }
            ApplyEnabledVisual(on);

            sw.Checked += (s, e) =>
            {
                p["enabled"] = JsonValue.Create(true);
                ApplyEnabledVisual(true);
                MarkDirty();
            };
            sw.Unchecked += (s, e) =>
            {
                // 只翻开关，不动数值：Lua 那边会把 disabled 的参数按原版处理，
                // 把已经下发的覆盖撤销掉；重新打开时你的数值还在，不用重调
                p["enabled"] = JsonValue.Create(false);
                ApplyEnabledVisual(false);
                MarkDirty();
            };

            wrap.Child = grid;
            return wrap;
        }

        // 三模式在参数行上的图标：= 绝对 / % 比例 / ± 偏移。
        // 用符号而不是文字，是为了让按钮窄到 34px 也不影响识别。
        private static string ModeIcon(string mode) => mode switch
        {
            "ratio" => "%",
            "offset" => "±",
            _ => "="
        };

        private static string ModeLabel(string mode) => mode switch
        {
            "ratio" => "比例（原值 × %）",
            "offset" => "偏移（原值 + Δ）",
            _ => "绝对（写死一个值）"
        };

        private static Button MakeResetButton(Action onClick)
        {
            var b = new Button
            {
                Content = "↺",
                Width = 30,
                Height = 30,
                Margin = new Thickness(6, 0, 0, 0),
                Padding = new Thickness(0),
                FontSize = 17,
                Foreground = Brush(CTextDim),
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                ToolTip = "恢复默认（也可以双击左边的名称）"
            };
            b.Click += (s, e) => onClick();
            return b;
        }

        // decimals >= 0 时强制按该小数位数显示（参数表里的 "decimals" 字段）。
        // 不给就用 step 推断：step>=1 整数、>=0.1 一位、其余两位。
        // 为什么需要显式指定：像「天光漏光」这种值域 0~1、但实际要用 0.0005 级别微调的参数，
        // 只按 step 推断会被截成 0.01，用户根本没法输进第三、四位。
        private static string Fmt(double v, double step, int decimals = -1)
        {
            if (decimals >= 0)
            {
                if (decimals > 6) decimals = 6;
                return v.ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
            }
            if (step >= 1) return ((int)Math.Round(v)).ToString(CultureInfo.InvariantCulture);
            if (step >= 0.1) return v.ToString("0.0", CultureInfo.InvariantCulture);
            if (step >= 0.01) return v.ToString("0.00", CultureInfo.InvariantCulture);
            if (step >= 0.001) return v.ToString("0.000", CultureInfo.InvariantCulture);
            return v.ToString("0.0000", CultureInfo.InvariantCulture);
        }

        private static double GetDouble(JsonObject o, string key, double def)
        {
            try
            {
                var n = o[key];
                if (n == null) return def;
                return n.GetValue<double>();
            }
            catch { return def; }
        }

        private static bool GetBool(JsonObject o, string key, bool def)
        {
            try
            {
                var n = o[key];
                if (n == null) return def;
                return n.GetValue<bool>();
            }
            catch { return def; }
        }

        private static SolidColorBrush Brush(string hex)
        {
            return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        }

        private void Header_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.Left)
            {
                try { DragMove(); } catch { }
            }
        }

        private void Close_Click(object sender, RoutedEventArgs e) => HideOverlay();

        /// <summary>
        /// 写心跳文件（内容为 UTC Unix 秒）。Lua 侧每隔十几秒读一次，
        /// 30 秒内更新过就认为面板活着，不会再执行 start（避免黑窗口一闪）。
        /// </summary>
        private void WriteHeartbeat()
        {
            try
            {
                var dir = Path.GetDirectoryName(JsonPath);
                if (dir == null) return;
                File.WriteAllText(Path.Combine(dir, "panel_heartbeat.txt"),
                    DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString());
            }
            catch { }
        }

        private void DeleteHeartbeat()
        {
            try
            {
                var dir = Path.GetDirectoryName(JsonPath);
                if (dir == null) return;
                var hb = Path.Combine(dir, "panel_heartbeat.txt");
                if (File.Exists(hb)) File.Delete(hb);
            }
            catch { }
        }

        protected override void OnClosed(EventArgs e)
        {
            try { UnregisterHotKey(_hwnd, HOTKEY_ID); } catch { }
            RestoreDisplayMode();
            if (_watcher != null) { _watcher.EnableRaisingEvents = false; _watcher.Dispose(); }
            // 托盘图标必须显式 Dispose，否则会在系统托盘里留一个点不掉的幽灵图标，
            // 要等鼠标划过才消失。
            try { if (_tray != null) { _tray.Visible = false; _tray.Dispose(); _tray = null; } } catch { }
            base.OnClosed(e);
        }
    }
}
