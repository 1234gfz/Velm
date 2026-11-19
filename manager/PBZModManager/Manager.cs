using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;

namespace PBZModManager;

// PBZFog 安装/卸载/检测 的核心逻辑（与界面无关，CLI 与 WPF 共用）。
public static class Manager
{
    public const string ModName = "PBZFog";
    private const int AppId = 4115450;
    public static readonly string[] ProxyNames =
        { "dwmapi.dll", "version.dll", "dxgi.dll", "d3d12.dll", "winmm.dll", "dbghelp.dll", "dinput8.dll" };

    // ---------------------------------------------------------------- 定位

    public static string? ResolveGame(string? gameArg, out string how)
    {
        if (!string.IsNullOrWhiteSpace(gameArg)) { how = "指定目录"; return NormalizeToSteamDir(gameArg!); }
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
                if (File.Exists(Path.Combine(steamDir, "PBZ.exe"))) { how = "Steam 库"; return steamDir; }
            }
        }
        how = "";
        return null;
    }

    public static string NormalizeToSteamDir(string p)
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

    public static bool IsGameRunning() => Process.GetProcessesByName("PBZ").Length > 0;

    // ---------------------------------------------------------------- 状态

    public static string StatusText(string gameSteam)
    {
        var sb = new StringBuilder();
        var ue4ss = Path.Combine(gameSteam, "ue4ss");
        sb.AppendLine($"游戏目录: {gameSteam}");
        sb.AppendLine($"PBZ.exe : {(File.Exists(Path.Combine(gameSteam, "PBZ.exe")) ? "有" : "无")}");
        sb.AppendLine($"UE4SS   : {(Directory.Exists(ue4ss) ? "有" : "无")}");
        sb.AppendLine($"模组    : {(Directory.Exists(Path.Combine(ue4ss, "Mods", ModName)) ? "已安装" : "未安装")}");
        sb.AppendLine($"游戏运行: {(IsGameRunning() ? "是（改动前请先关游戏）" : "否")}");
        sb.AppendLine("代理 DLL:");
        bool any = false;
        foreach (var n in ProxyNames)
        {
            var p = Path.Combine(gameSteam, n);
            if (File.Exists(p)) { any = true; sb.AppendLine($"  - {n,-14} {new FileInfo(p).Length / 1024.0,8:F1} KB"); }
        }
        if (!any) sb.AppendLine("  （无）");
        return sb.ToString();
    }

    // ---------------------------------------------------------------- 安装

    public static void Install(string gameSteam, string sourceDir, string? ue4ssDir,
        bool useOwnUe4ss, bool forceProxy, bool dryRun, Action<string> log)
    {
        if (!Directory.Exists(sourceDir) || !Directory.Exists(Path.Combine(sourceDir, "Scripts")))
            throw new Exception($"找不到模组源目录（应含 Scripts\\）: {sourceDir}");
        if (IsGameRunning()) throw new Exception("游戏正在运行。请先关闭游戏（本工具不会替你关）。");
        if (dryRun) log("（dry-run：只检查不落盘）");

        var ue4ss = Path.Combine(gameSteam, "ue4ss");
        var modsDir = Path.Combine(ue4ss, "Mods");
        var modDir = Path.Combine(modsDir, ModName);
        bool haveOwn = Directory.Exists(ue4ss) && File.Exists(Path.Combine(ue4ss, "UE4SS.dll"));

        if (!dryRun)
        {
            if (ue4ssDir != null) InstallBundledUe4ss(gameSteam, ue4ssDir, forceProxy, log);
            else if (useOwnUe4ss || haveOwn)
            {
                if (!haveOwn) throw new Exception($"指定用已有 UE4SS，但 {ue4ss} 下没有 UE4SS.dll。");
                log("使用你已安装的 UE4SS。");
            }
            else throw new Exception("没检测到 UE4SS。请提供自带包（--ue4ss）、先自行安装 UE4SS，或选择「使用已有」。");

            Directory.CreateDirectory(modsDir);
            var backupRoot = Path.Combine(modsDir, $"_backup_pbzmanager_{DateTime.Now:yyyyMMdd-HHmmss}");
            if (Directory.Exists(modDir))
            {
                Directory.CreateDirectory(backupRoot);
                Directory.Move(modDir, Path.Combine(backupRoot, ModName));
                log("已备份旧模组 -> " + backupRoot);
            }
            CopyDir(sourceDir, modDir);
            log($"已复制模组文件（{CountLua(modDir)} 个 Lua）。");
            EnsureModsTxt(Path.Combine(modsDir, "mods.txt"), backupRoot, log);
        }
        log("完成。启动游戏后按 F8 呼出面板。");
    }

    private static void InstallBundledUe4ss(string gameSteam, string vendor, bool forceProxy, Action<string> log)
    {
        var inner = Path.Combine(vendor, "ue4ss");
        var srcUe4ss = Directory.Exists(inner) ? inner : vendor;
        if (!File.Exists(Path.Combine(srcUe4ss, "UE4SS.dll")))
            throw new Exception($"自带 UE4SS 目录里没有 UE4SS.dll: {srcUe4ss}");

        var others = ProxyNames.Where(n => n != "dwmapi.dll" && File.Exists(Path.Combine(gameSteam, n))).ToArray();
        if (others.Length > 0 && !forceProxy)
            throw new Exception("检测到其它注入代理 DLL：" + string.Join(", ", others) +
                "。它们可能与 UE4SS 冲突。确认要装请勾选/加 --force-proxy。");

        var proxyDst = Path.Combine(gameSteam, "dwmapi.dll");
        if (File.Exists(proxyDst))
        {
            var bak = proxyDst + $".bak-{DateTime.Now:yyyyMMdd-HHmmss}";
            File.Copy(proxyDst, bak, true);
            log("已备份原 dwmapi.dll -> " + bak);
        }
        CopyDir(srcUe4ss, Path.Combine(gameSteam, "ue4ss"));
        var vendorProxy = Path.Combine(vendor, "dwmapi.dll");
        if (File.Exists(vendorProxy)) File.Copy(vendorProxy, proxyDst, true);
        else log("提示：自带包里没有 dwmapi.dll，请确认已有 UE4SS 注入代理。");
        log("已安装自带 UE4SS。");
    }

    // ---------------------------------------------------------------- 卸载

    public static void Uninstall(string gameSteam, bool dryRun, Action<string> log)
    {
        if (IsGameRunning()) throw new Exception("游戏正在运行。请先关闭游戏再卸载。");
        if (dryRun) { log("（dry-run：只检查不落盘）"); return; }
        var modsDir = Path.Combine(gameSteam, "ue4ss", "Mods");
        var modDir = Path.Combine(modsDir, ModName);
        var modsTxt = Path.Combine(modsDir, "mods.txt");
        if (Directory.Exists(modDir)) { Directory.Delete(modDir, true); log("已删除模组目录。"); }
        else log("未发现模组目录（可能未安装）。");
        if (File.Exists(modsTxt))
        {
            var bak = modsTxt + $".bak-{DateTime.Now:yyyyMMdd-HHmmss}";
            File.Copy(modsTxt, bak, true);
            var lines = File.ReadAllLines(modsTxt).Where(l => KeyOf(l) != ModName).ToArray();
            File.WriteAllLines(modsTxt, lines, new UTF8Encoding(false));
            log("已从 mods.txt 移除 PBZFog。");
        }
        log("卸载完成（UE4SS 与面板/预设保留，按需自行清理）。");
    }

    // ---------------------------------------------------------------- 工具

    private static void EnsureModsTxt(string modsTxt, string backupRoot, Action<string> log)
    {
        var lines = File.Exists(modsTxt) ? File.ReadAllLines(modsTxt).ToList() : new List<string>();
        if (File.Exists(modsTxt)) { Directory.CreateDirectory(backupRoot); File.Copy(modsTxt, Path.Combine(backupRoot, "mods.txt"), true); }
        var idx = lines.FindIndex(l => KeyOf(l) == ModName);
        if (idx >= 0) lines[idx] = $"{ModName} : 1"; else lines.Add($"{ModName} : 1");
        File.WriteAllLines(modsTxt, lines, new UTF8Encoding(false));
        log("已在 mods.txt 启用 PBZFog : 1");
    }

    public static string KeyOf(string line)
    {
        var t = line.Trim();
        if (t.StartsWith(";") || t.Length == 0) return "";
        var i = t.IndexOf(':');
        return (i < 0 ? t : t.Substring(0, i)).Trim();
    }

    private static int CountLua(string dir) => Directory.Exists(dir) ? Directory.GetFiles(dir, "*.lua", SearchOption.AllDirectories).Length : 0;

    public static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
        {
            var dst = Path.Combine(to, Path.GetRelativePath(from, f));
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(f, dst, true);
        }
    }

    // ---------------------------------------------------------------- 版本检查

    public static string LocalVersion()
    {
        try { var p = Path.Combine(AppContext.BaseDirectory, "VERSION"); if (File.Exists(p)) return File.ReadAllText(p).Trim(); } catch { }
        return "?";
    }

    // 读取仓库里的最新版本号；proxy 形如 http://127.0.0.1:7897，可为空。失败抛异常。
    public static string LatestVersion(string? proxy = null)
    {
        var url = "https://raw.githubusercontent.com/1234gfz/Velm/main/VERSION";
        using var handler = new HttpClientHandler();
        if (!string.IsNullOrWhiteSpace(proxy))
        {
            var uri = new Uri(proxy!.Contains("://") ? proxy : "http://" + proxy);
            handler.Proxy = new System.Net.WebProxy(uri);
            handler.UseProxy = true;
        }
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Velm-Updater");
        return http.GetStringAsync(url).GetAwaiter().GetResult().Trim();
    }

    // 返回 1 表示 remote 更新，0 相同，-1 本地更新或无法比较。
    public static int CompareVersion(string local, string remote)
    {
        if (Version.TryParse(local, out var l) && Version.TryParse(remote, out var r)) return r.CompareTo(l);
        return string.Equals(local, remote) ? 0 : 1;
    }
}
