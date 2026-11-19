using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

// PBZModManager MVP —— 安装 / 检测 / 卸载 PBZFog 模组（可选：连同自带 UE4SS 一起装）。
// 用法：
//   PBZModManager status   [--game <游戏根或platform\steam>]
//   PBZModManager install  [--game <...>] [--source <含 Scripts 的 PBZFog 目录>]
//                          [--ue4ss <自带UE4SS解压目录>] [--use-own-ue4ss] [--force-proxy] [--dry-run]
//   PBZModManager uninstall[--game <...>] [--dry-run]
//   PBZModManager repair   [--game <...>] [--source <...>] [--ue4ss <...>] [--use-own-ue4ss] [--force-proxy]
// 不带 --game 时自动从 Steam 库定位（appid 4115450）。

internal static class Program
{
    private const string ModName = "PBZFog";
    private const int AppId = 4115450;
    private static string _logPath = "";
    private static readonly string[] ProxyNames =
        { "dwmapi.dll", "version.dll", "dxgi.dll", "d3d12.dll", "winmm.dll", "dbghelp.dll", "dinput8.dll" };

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        var cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
        var opt = ParseOpts(args.Skip(1).ToArray());
        _logPath = Path.Combine(AppContext.BaseDirectory, "manager.log");
        try
        {
            switch (cmd)
            {
                case "status": return DoStatus(opt);
                case "install": return DoInstall(opt);
                case "repair": return DoInstall(opt);
                case "uninstall": return DoUninstall(opt);
                default: PrintHelp(); return 0;
            }
        }
        catch (Exception ex) { Log("错误: " + ex.Message, ConsoleColor.Red); return 1; }
    }

    // ---------------------------------------------------------------- status

    private static int DoStatus(Options opt)
    {
        var (gameSteam, how) = ResolveGame(opt);
        Log("== 状态 ==", ConsoleColor.Cyan);
        if (gameSteam == null) { Log("未找到游戏目录，请用 --game 指定。", ConsoleColor.Yellow); return 2; }
        Console.WriteLine($"  游戏目录: {gameSteam}   (定位: {how})");
        Console.WriteLine($"  PBZ.exe : {(File.Exists(Path.Combine(gameSteam, "PBZ.exe")) ? "有" : "无")}");
        var ue4ss = Path.Combine(gameSteam, "ue4ss");
        Console.WriteLine($"  UE4SS   : {(Directory.Exists(ue4ss) ? "有" : "无")}");
        Console.WriteLine($"  模组    : {(Directory.Exists(Path.Combine(ue4ss, "Mods", ModName)) ? "已安装" : "未安装")}");
        Console.WriteLine($"  游戏运行: {(IsGameRunning() ? "是（改动前请先关游戏）" : "否")}");
        Console.WriteLine("  代理 DLL:");
        foreach (var n in ProxyNames)
        {
            var p = Path.Combine(gameSteam, n);
            if (File.Exists(p)) Console.WriteLine($"    - {n,-14} {new FileInfo(p).Length / 1024.0,8:F1} KB");
        }
        return 0;
    }

    // ---------------------------------------------------------------- install / repair

    private static int DoInstall(Options opt)
    {
        var (gameSteam, how) = ResolveGame(opt);
        if (gameSteam == null) { Log("未找到游戏目录，请用 --game 指定。", ConsoleColor.Yellow); return 2; }
        var src = opt.Source ?? Path.Combine(AppContext.BaseDirectory, ModName);
        if (!Directory.Exists(src) || !Directory.Exists(Path.Combine(src, "Scripts")))
            throw new Exception($"找不到模组源目录（应含 Scripts\\）: {src}  —— 用 --source 指定");

        Log("== 安装/修复 PBZFog ==", ConsoleColor.Cyan);
        Console.WriteLine($"  游戏: {gameSteam}");
        Console.WriteLine($"  源  : {src}");
        if (IsGameRunning()) throw new Exception("游戏正在运行。请先关闭游戏（本工具不会替你关）。");
        if (opt.DryRun) Log("（dry-run：只打印不落盘）", ConsoleColor.Yellow);

        var ue4ss = Path.Combine(gameSteam, "ue4ss");
        var modsDir = Path.Combine(ue4ss, "Mods");
        var modDir = Path.Combine(modsDir, ModName);

        // 0) UE4SS：三选一 —— 自带包 / 用已有的 / 报错
        var haveOwn = Directory.Exists(ue4ss) && File.Exists(Path.Combine(ue4ss, "UE4SS.dll"));
        if (!opt.DryRun)
        {
            if (opt.Ue4ssDir != null)
            {
                InstallBundledUe4ss(gameSteam, opt.Ue4ssDir, opt.ForceProxy);
            }
            else if (opt.UseOwnUe4ss || haveOwn)
            {
                if (!haveOwn) throw new Exception($"指定用已有 UE4SS，但 {ue4ss} 下没有 UE4SS.dll。");
                Log("使用你已安装的 UE4SS。", ConsoleColor.Green);
            }
            else
            {
                throw new Exception("没检测到 UE4SS。请用 --ue4ss 指定自带包（含 ue4ss\\UE4SS.dll 与 dwmapi.dll），或先自行安装 UE4SS，或加 --use-own-ue4ss 跳过。");
            }
        }

        if (!opt.DryRun)
        {
            Directory.CreateDirectory(modsDir);
            var backupRoot = Path.Combine(modsDir, $"_backup_pbzmanager_{DateTime.Now:yyyyMMdd-HHmmss}");
            if (Directory.Exists(modDir))
            {
                Directory.CreateDirectory(backupRoot);
                Directory.Move(modDir, Path.Combine(backupRoot, ModName));
                Log("已备份旧模组 -> " + backupRoot, ConsoleColor.DarkGray);
            }
            CopyDir(src, modDir);
            Log("已复制模组文件（" + CountLua(modDir) + " 个 Lua）。", ConsoleColor.Green);
            EnsureModsTxt(Path.Combine(modsDir, "mods.txt"), backupRoot);
            Log("已在 mods.txt 启用 PBZFog : 1", ConsoleColor.Green);
        }
        Log("完成。启动游戏后按 F8 呼出面板。", ConsoleColor.Green);
        return 0;
    }

    private static void InstallBundledUe4ss(string gameSteam, string vendor, bool forceProxy)
    {
        var inner = Path.Combine(vendor, "ue4ss");
        var srcUe4ss = Directory.Exists(inner) ? inner : vendor;
        if (!File.Exists(Path.Combine(srcUe4ss, "UE4SS.dll")))
            throw new Exception($"自带 UE4SS 目录里没有 UE4SS.dll: {srcUe4ss}");

        // 代理冲突检测：除 dwmapi 外若还有别的注入代理，先提醒
        var others = ProxyNames.Where(n => n != "dwmapi.dll" && File.Exists(Path.Combine(gameSteam, n))).ToArray();
        if (others.Length > 0 && !forceProxy)
            throw new Exception("检测到其它注入代理 DLL：" + string.Join(", ", others) +
                "。它们可能与 UE4SS 冲突。确认要装，加 --force-proxy。");

        // 备份已有 dwmapi.dll
        var proxyDst = Path.Combine(gameSteam, "dwmapi.dll");
        if (File.Exists(proxyDst))
        {
            var bak = proxyDst + $".bak-{DateTime.Now:yyyyMMdd-HHmmss}";
            File.Copy(proxyDst, bak, true);
            Log("已备份原 dwmapi.dll -> " + bak, ConsoleColor.DarkGray);
        }

        // 拷贝 UE4SS 运行时（合并，不删已有 Mods）
        CopyDir(srcUe4ss, Path.Combine(gameSteam, "ue4ss"));
        var vendorProxy = Path.Combine(vendor, "dwmapi.dll");
        if (File.Exists(vendorProxy)) File.Copy(vendorProxy, proxyDst, true);
        else Log("提示：自带包里没有 dwmapi.dll，请确认你已有 UE4SS 注入代理。", ConsoleColor.Yellow);
        Log("已安装自带 UE4SS。", ConsoleColor.Green);
    }

    // ---------------------------------------------------------------- uninstall

    private static int DoUninstall(Options opt)
    {
        var (gameSteam, how) = ResolveGame(opt);
        if (gameSteam == null) { Log("未找到游戏目录，请用 --game 指定。", ConsoleColor.Yellow); return 2; }
        Log("== 卸载 PBZFog ==", ConsoleColor.Cyan);
        if (IsGameRunning()) throw new Exception("游戏正在运行。请先关闭游戏再卸载。");
        if (opt.DryRun) { Log("（dry-run：只打印不落盘）", ConsoleColor.Yellow); return 0; }
        var modsDir = Path.Combine(gameSteam, "ue4ss", "Mods");
        var modDir = Path.Combine(modsDir, ModName);
        var modsTxt = Path.Combine(modsDir, "mods.txt");
        if (Directory.Exists(modDir)) { Directory.Delete(modDir, true); Log("已删除模组目录。", ConsoleColor.Green); }
        else Log("未发现模组目录（可能未安装）。", ConsoleColor.DarkGray);
        if (File.Exists(modsTxt))
        {
            var bak = modsTxt + $".bak-{DateTime.Now:yyyyMMdd-HHmmss}";
            File.Copy(modsTxt, bak, true);
            var lines = File.ReadAllLines(modsTxt).Where(l => KeyOf(l) != ModName).ToArray();
            File.WriteAllLines(modsTxt, lines, new UTF8Encoding(false));
            Log("已从 mods.txt 移除 PBZFog。", ConsoleColor.Green);
        }
        Log("卸载完成（UE4SS 与面板/预设保留，按需自行清理）。", ConsoleColor.Green);
        return 0;
    }

    // ---------------------------------------------------------------- 路径解析

    private static (string? steamDir, string how) ResolveGame(Options opt)
    {
        if (!string.IsNullOrWhiteSpace(opt.Game)) return (NormalizeToSteamDir(opt.Game!), "--game");
        foreach (var steamRoot in SteamRoots())
        {
            var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf)) continue;
            foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s*\"([^\"]+)\""))
            {
                var lib = m.Groups[1].Value.Replace("\\\\", "\\");
                var acf = Path.Combine(lib, "steamapps", $"appmanifest_{AppId}.acf");
                if (!File.Exists(acf)) continue;
                var im = Regex.Match(File.ReadAllText(acf), "\"installdir\"\\s*\"([^\"]+)\"");
                var inst = im.Success ? im.Groups[1].Value : "PBZ";
                var steamDir = Path.Combine(lib, "steamapps", "common", inst, "platform", "steam");
                if (File.Exists(Path.Combine(steamDir, "PBZ.exe"))) return (steamDir, "Steam 库");
            }
        }
        return (null, "");
    }

    private static string NormalizeToSteamDir(string p)
    {
        p = p.TrimEnd('\\', '/');
        if (File.Exists(Path.Combine(p, "PBZ.exe"))) return p;
        var s = Path.Combine(p, "platform", "steam");
        if (File.Exists(Path.Combine(s, "PBZ.exe"))) return s;
        return p;
    }

    private static IEnumerable<string> SteamRoots()
    {
        var set = new List<string>();
        foreach (var d in new[] { "C", "D", "E", "F", "G" }) set.Add($@"{d}:\Program Files (x86)\Steam");
        set.Add(@"C:\Program Files\Steam");
        return set.Where(Directory.Exists);
    }

    // ---------------------------------------------------------------- 工具

    private static void EnsureModsTxt(string modsTxt, string backupRoot)
    {
        var lines = File.Exists(modsTxt) ? File.ReadAllLines(modsTxt).ToList() : new List<string>();
        if (File.Exists(modsTxt)) { Directory.CreateDirectory(backupRoot); File.Copy(modsTxt, Path.Combine(backupRoot, "mods.txt"), true); }
        var idx = lines.FindIndex(l => KeyOf(l) == ModName);
        if (idx >= 0) lines[idx] = $"{ModName} : 1"; else lines.Add($"{ModName} : 1");
        File.WriteAllLines(modsTxt, lines, new UTF8Encoding(false));
    }

    private static string KeyOf(string line)
    {
        var t = line.Trim();
        if (t.StartsWith(";") || t.Length == 0) return "";
        var i = t.IndexOf(':');
        return (i < 0 ? t : t.Substring(0, i)).Trim();
    }

    private static bool IsGameRunning() => Process.GetProcessesByName("PBZ").Length > 0;

    private static int CountLua(string dir) => Directory.Exists(dir) ? Directory.GetFiles(dir, "*.lua", SearchOption.AllDirectories).Length : 0;

    private static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
        {
            var dst = Path.Combine(to, Path.GetRelativePath(from, f));
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(f, dst, true);
        }
    }

    private static void Log(string msg, ConsoleColor color = ConsoleColor.Gray)
    {
        Console.ForegroundColor = color; Console.WriteLine(msg); Console.ResetColor();
        try { File.AppendAllText(_logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {msg}\n", new UTF8Encoding(false)); } catch { }
    }

    private static void PrintHelp()
    {
        Console.WriteLine("PBZModManager — PBZFog 安装/检测/卸载");
        Console.WriteLine("  status   [--game <dir>]");
        Console.WriteLine("  install  [--game <dir>] [--source <PBZFog目录>] [--ue4ss <自带UE4SS目录>] [--use-own-ue4ss] [--force-proxy] [--dry-run]");
        Console.WriteLine("  repair   [--game <dir>] [--source <..>] [--ue4ss <..>] [--use-own-ue4ss] [--force-proxy]");
        Console.WriteLine("  uninstall[--game <dir>] [--dry-run]");
    }

    private sealed class Options
    {
        public string? Game; public string? Source; public string? Ue4ssDir;
        public bool UseOwnUe4ss; public bool ForceProxy; public bool DryRun;
    }

    private static Options ParseOpts(string[] a)
    {
        var o = new Options();
        for (int i = 0; i < a.Length; i++)
        {
            switch (a[i])
            {
                case "--game": o.Game = i + 1 < a.Length ? a[++i] : null; break;
                case "--source": o.Source = i + 1 < a.Length ? a[++i] : null; break;
                case "--ue4ss": o.Ue4ssDir = i + 1 < a.Length ? a[++i] : null; break;
                case "--use-own-ue4ss": o.UseOwnUe4ss = true; break;
                case "--force-proxy": o.ForceProxy = true; break;
                case "--dry-run": o.DryRun = true; break;
            }
        }
        return o;
    }
}
