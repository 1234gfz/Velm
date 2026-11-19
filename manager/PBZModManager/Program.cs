using PBZModManager;
using System.Text;

// 命令行入口（自动化/测试用；对外发布用同目录的窗口版 PBZModManager.exe）。
internal static class Program
{
    private static string _logPath = "";

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        var cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
        var o = ParseOpts(args.Skip(1).ToArray());
        _logPath = Path.Combine(AppContext.BaseDirectory, "manager.log");

        void Log(string m)
        {
            Console.WriteLine(m);
            try { File.AppendAllText(_logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {m}\n", new UTF8Encoding(false)); } catch { }
        }

        try
        {
            switch (cmd)
            {
                case "status":
                    {
                        var g = Manager.ResolveGame(o.Game, out var how);
                        if (g == null) { Log("未找到游戏目录，请用 --game 指定。"); return 2; }
                        Console.WriteLine($"== 状态 ==  ({how})");
                        Console.Write(Manager.StatusText(g));
                        return 0;
                    }
                case "install":
                case "repair":
                    {
                        var g = Manager.ResolveGame(o.Game, out _);
                        if (g == null) { Log("未找到游戏目录，请用 --game 指定。"); return 2; }
                        var defSrc = Path.Combine(AppContext.BaseDirectory, "payload", Manager.ModName);
                        if (!Directory.Exists(defSrc)) defSrc = Path.Combine(AppContext.BaseDirectory, Manager.ModName);
                        var src = o.Source ?? defSrc;
                        Log("== 安装/修复 PBZFog ==");
                        Log("游戏: " + g);
                        Log("源  : " + src);
                        Manager.Install(g, src, o.Ue4ss, o.UseOwn, o.ForceProxy, o.DryRun, Log);
                        return 0;
                    }
                case "uninstall":
                    {
                        var g = Manager.ResolveGame(o.Game, out _);
                        if (g == null) { Log("未找到游戏目录，请用 --game 指定。"); return 2; }
                        Log("== 卸载 PBZFog ==");
                        Manager.Uninstall(g, o.DryRun, Log);
                        return 0;
                    }
                default:
                    PrintHelp();
                    return 0;
            }
        }
        catch (Exception ex) { Log("错误: " + ex.Message); return 1; }
    }

    private static void PrintHelp()
    {
        Console.WriteLine("PBZModManager（命令行）— PBZFog 安装/检测/卸载");
        Console.WriteLine("  status   [--game <dir>]");
        Console.WriteLine("  install  [--game <dir>] [--source <PBZFog目录>] [--ue4ss <自带UE4SS目录>] [--use-own-ue4ss] [--force-proxy] [--dry-run]");
        Console.WriteLine("  repair   （同 install）");
        Console.WriteLine("  uninstall[--game <dir>] [--dry-run]");
    }

    private sealed class Options
    {
        public string? Game; public string? Source; public string? Ue4ss;
        public bool UseOwn; public bool ForceProxy; public bool DryRun;
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
                case "--ue4ss": o.Ue4ss = i + 1 < a.Length ? a[++i] : null; break;
                case "--use-own-ue4ss": o.UseOwn = true; break;
                case "--force-proxy": o.ForceProxy = true; break;
                case "--dry-run": o.DryRun = true; break;
            }
        }
        return o;
    }
}
