using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

// PBZModManager MVP —— 安装 / 检测 / 卸载 PBZFog 模组。
// 用法：
//   PBZModManager status   [--game <游戏根或platform\steam>]
//   PBZModManager install  [--game <...>] [--source <含 Scripts 的 PBZFog 目录>] [--dry-run]
//   PBZModManager uninstall[--game <...>] [--dry-run]
//   PBZModManager repair   [--game <...>] [--source <...>]
// 不带 --game 时自动从 Steam 库定位（appid 4115450）。

internal static class Program
{
    private const string ModName = "PBZFog";
    private const int AppId = 4115450;
    private static string _logPath = "";

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        var cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
        var opt = ParseOpts(args.Skip(1).ToArray());
        var exeDir = AppContext.BaseDirectory;
        _logPath = Path.Combine(exeDir, "manager.log");

        try
        {
            switch (cmd)
            {
                case "status": return DoStatus(opt);
                case "install": return DoInstall(opt, isRepair: false);
                case "repair": return DoInstall(opt, isRepair: true);
                case "uninstall": return DoUninstall(opt);
                default:
                    PrintHelp();
                    return 0;
            }
        }
        catch (Exception ex)
        {
            Log("错误: " + ex.Message, ConsoleColor.Red);
            return 1;
        }
    }

    // ---------------------------------------------------------------- 命令

    private static int DoStatus(Options opt)
    {
        var (gameSteam, how) = ResolveGame(opt);
        Log("== 状态 ==", ConsoleColor.Cyan);
        if (gameSteam == null) { Log("未找到游戏目录，请用 --game 指定。", ConsoleColor.Yellow); return 2; }
        Console.WriteLine($"  游戏目录: {gameSteam}   (定位方式: {how})");
        var exe = Path.Combine(gameSteam, "PBZ.exe");
        Console.WriteLine($"  PBZ.exe : {(File.Exists(exe) ? "有" : "无")}");
        var ue4ss = Path.Combine(gameSteam, "ue4ss");
        var modDir = Path.Combine(ue4ss, "Mods", ModName);
        Console.WriteLine($"  UE4SS   : {(Directory.Exists(ue4ss) ? "有" : "无")}  ({ue4ss})");
        Console.WriteLine($"  模组    : {(Directory.Exists(modDir) ? "已安装" : "未安装")}  ({modDir})");
        Console.WriteLine($"  mods.txt: {Path.Combine(ue4ss, "Mods", "mods.txt")}");
        Console.WriteLine($"  游戏运行: {(IsGameRunning() ? "是（改动前请先关游戏）" : "否")}");

        Console.WriteLine("  代理 DLL:");
        foreach (var n in new[] { "dwmapi.dll", "version.dll", "dxgi.dll", "d3d12.dll", "winmm.dll", "dbghelp.dll", "dinput8.dll" })
        {
            var p = Path.Combine(gameSteam, n);
            if (File.Exists(p)) Console.WriteLine($"    - {n,-14} {new FileInfo(p).Length / 1024.0,8:F1} KB");
        }
        return 0;
    }

    private static int DoInstall(Options opt, bool isRepair)
    {
        var (gameSteam, how) = ResolveGame(opt);
        if (gameSteam == null) { Log("未找到游戏目录，请用 --game 指定。", ConsoleColor.Yellow); return 2; }
        var src = opt.Source ?? Path.Combine(AppContext.BaseDirectory, ModName);
        if (!Directory.Exists(src) || !Directory.Exists(Path.Combine(src, "Scripts")))
            throw new Exception($"找不到模组源目录（应含 Scripts\\）: {src}  —— 用 --source 指定");

        Log($"== {(isRepair ? "修复" : "安装")}  PBZFog ==", ConsoleColor.Cyan);
        Console.WriteLine($"  游戏: {gameSteam}");
        Console.WriteLine($"  源  : {src}");
        if (IsGameRunning()) throw new Exception("游戏正在运行。请先关闭游戏再安装/修复（本工具不会替你关游戏）。");

        var ue4ss = Path.Combine(gameSteam, "ue4ss");
        var modsDir = Path.Combine(ue4ss, "Mods");
        var modDir = Path.Combine(modsDir, ModName);
        var modsTxt = Path.Combine(modsDir, "mods.txt");

        if (opt.DryRun) { Log("（dry-run：只打印不落盘）", ConsoleColor.Yellow); }

        // 1) 检测 UE4SS
        if (!Directory.Exists(ue4ss))
            Log("提示：没检测到 ue4ss 目录。需先装 UE4SS（或用自带 UE4SS 的安装包）。", ConsoleColor.Yellow);

        if (!opt.DryRun)
        {
            Directory.CreateDirectory(modsDir);
            var backupRoot = Path.Combine(modsDir, $"_backup_pbzmanager_{DateTime.Now:yyyyMMdd-HHmmss}");
            // 2) 备份旧模组
            if (Directory.Exists(modDir))
            {
                Directory.CreateDirectory(backupRoot);
                MoveDir(modDir, Path.Combine(backupRoot, ModName));
                Log("已备份旧模组 -> " + backupRoot, ConsoleColor.DarkGray);
            }
            // 3) 拷贝新模组
            CopyDir(src, modDir);
            Log("已复制模组文件。", ConsoleColor.Green);
            // 4) mods.txt
            EnsureModsTxt(modsTxt, backupRoot);
            Log("已在 mods.txt 启用 PBZFog : 1", ConsoleColor.Green);
        }
        Log("完成。启动游戏后按 F8 呼出面板。", ConsoleColor.Green);
        return 0;
    }

    private static int DoUninstall(Options opt)
    {
        var (gameSteam, how) = ResolveGame(opt);
        if (gameSteam == null) { Log("未找到游戏目录，请用 --game 指定。", ConsoleColor.Yellow); return 2; }
        Log("== 卸载 PBZFog ==", ConsoleColor.Cyan);
        if (IsGameRunning()) throw new Exception("游戏正在运行。请先关闭游戏再卸载。");
        var modsDir = Path.Combine(gameSteam, "ue4ss", "Mods");
        var modDir = Path.Combine(modsDir, ModName);
        var modsTxt = Path.Combine(modsDir, "mods.txt");
        if (opt.DryRun) { Log("（dry-run：只打印不落盘）", ConsoleColor.Yellow); return 0; }

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
        Log("卸载完成（面板/预设等留在原处可由你手动清理）。", ConsoleColor.Green);
        return 0;
    }

    // ---------------------------------------------------------------- 路径解析

    private static (string? steamDir, string how) ResolveGame(Options opt)
    {
        if (!string.IsNullOrWhiteSpace(opt.Game))
        {
            var g = NormalizeToSteamDir(opt.Game!);
            return (g, "--game");
        }
        // 自动：Steam libraryfolders.vdf
        foreach (var steamRoot in SteamRoots())
        {
            var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf)) continue;
            var txt = File.ReadAllText(vdf);
            foreach (Match m in Regex.Matches(txt, "\"path\"\\s*\"([^\"]+)\""))
            {
                var lib = m.Groups[1].Value.Replace("\\\\", "\\");
                var acf = Path.Combine(lib, "steamapps", $"appmanifest_{AppId}.acf");
                if (!File.Exists(acf)) continue;
                var acfTxt = File.ReadAllText(acf);
                var im = Regex.Match(acfTxt, "\"installdir\"\\s*\"([^\"]+)\"");
                var inst = im.Success ? im.Groups[1].Value : "PBZ";
                var gameRoot = Path.Combine(lib, "steamapps", "common", inst);
                var steamDir = Path.Combine(gameRoot, "platform", "steam");
                if (File.Exists(Path.Combine(steamDir, "PBZ.exe"))) return (steamDir, "Steam 库");
            }
        }
        return (null, "");
    }

    private static string NormalizeToSteamDir(string p)
    {
        p = p.TrimEnd('\\', '/');
        if (File.Exists(Path.Combine(p, "PBZ.exe"))) return p;                       // 已是 platform\steam
        var s = Path.Combine(p, "platform", "steam");
        if (File.Exists(Path.Combine(s, "PBZ.exe"))) return s;                       // 给了游戏根
        return p; // 原样返回，后续会因找不到 PBZ.exe 报错
    }

    private static IEnumerable<string> SteamRoots()
    {
        var set = new List<string>();
        foreach (var d in new[] { "C", "D", "E", "F", "G" })
            set.Add($@"{d}:\Program Files (x86)\Steam");
        set.Add(@"C:\Program Files\Steam");
        return set.Where(Directory.Exists);
    }

    // ---------------------------------------------------------------- 工具

    private static void EnsureModsTxt(string modsTxt, string backupRoot)
    {
        var lines = File.Exists(modsTxt) ? File.ReadAllLines(modsTxt).ToList() : new List<string>();
        if (File.Exists(modsTxt))
        {
            Directory.CreateDirectory(backupRoot);
            File.Copy(modsTxt, Path.Combine(backupRoot, "mods.txt"), true);
        }
        var idx = lines.FindIndex(l => KeyOf(l) == ModName);
        if (idx >= 0) lines[idx] = $"{ModName} : 1";
        else lines.Add($"{ModName} : 1");
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

    private static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(from, f);
            var dst = Path.Combine(to, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(f, dst, true);
        }
    }

    private static void MoveDir(string from, string to)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(to)!);
        Directory.Move(from, to);
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
        Console.WriteLine("  install  [--game <dir>] [--source <PBZFog目录>] [--dry-run]");
        Console.WriteLine("  repair   [--game <dir>] [--source <PBZFog目录>]");
        Console.WriteLine("  uninstall[--game <dir>] [--dry-run]");
    }

    private sealed class Options
    {
        public string? Game; public string? Source; public bool DryRun;
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
                case "--dry-run": o.DryRun = true; break;
            }
        }
        return o;
    }
}
