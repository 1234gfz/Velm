#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""工程版 ↔ 游戏版 Lua 代码同步（整目录）。

游戏目录里的 Lua 才是真正在跑的版本，工程目录里的是版本管理副本。
两边容易搞混，这个脚本负责对齐 + 校验。

重构后 PBZFog 不再是单个 main.lua，而是：
    Scripts/main.lua          装配 + 主循环
    core/*.lua                基础设施（json / log / ue / store / world）
    params/*.lua              参数引擎、路由表、schema
    params/handlers/*.lua     每种 handler 的实现
    features/*.lua            钩子、面板、光照探测

所以同步单位从「一个文件」变成「一整棵目录树」，但参数表 pbz_tweaker.json
仍然单独处理 —— 它是用户数据，绝不能覆盖。

用法：
  python tools/sync_lua.py push    # 工程 → 游戏（改完代码后用这个）
  python tools/sync_lua.py pull    # 游戏 → 工程（把游戏里的改动收回工程）
  python tools/sync_lua.py diff    # 只看差异，不动文件

注意：本机没有可用的 Python 时，用 tools/sync_lua.ps1，功能等价。
"""

import filecmp
import io
import os
import shutil
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME_MOD = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZFog"

SRC_ROOT = os.path.join(PROJ, "lua", "PBZFog")
DST_ROOT = GAME_MOD

# 参数表单独处理：它是用户数据（面板里调好的值），不是代码。
SRC_JSON = os.path.join(SRC_ROOT, "pbz_tweaker.json")
DST_JSON = os.path.join(DST_ROOT, "pbz_tweaker.json")

# 只在游戏侧存在的东西，push 时绝不能删：用户的运行时数据。
GAME_ONLY = {
    "pbz_pporig.json",
    "pbz_baseline.json",
    "pbz_presets.json",
    "panel_hotkey.log",
    "panel_heartbeat.txt",
    "config.txt",
    "DESIGN.md",
}


def read(p):
    return io.open(p, encoding="utf-8").read()


def lua_files(root):
    """返回 root 下所有 .lua 的相对路径（统一用 / 分隔）。"""
    out = []
    for base, _dirs, names in os.walk(root):
        for n in names:
            if n.endswith(".lua"):
                rel = os.path.relpath(os.path.join(base, n), root)
                out.append(rel.replace("\\", "/"))
    return sorted(out)


def check_lua_dir(root):
    """用真 Lua 解析器校验整棵目录。返回 (ok, 问题列表)。"""
    try:
        from luaparser import ast
    except ImportError:
        return True, ["跳过（未装 luaparser）"]
    bad = []
    for rel in lua_files(root):
        try:
            ast.parse(read(os.path.join(root, rel)))
        except Exception as e:
            bad.append("%s: %s" % (rel, str(e)[:200]))
    return (not bad), bad


def push_json():
    """推送参数表 —— 只补「新增的参数」，绝不覆盖游戏里已有的值。

    踩过的坑（重复踩了两次）：直接 copy 工程版 JSON 到游戏，
    会把用户在面板里调好的 value / enabled 全部重置成工程版里的默认值，
    表现就是「一编译雾就坏了」。工程版是结构定义，游戏版才是用户数据的真相。

    正确做法：以游戏版为基准，只把工程版里「游戏版没有的参数」追加进去。
    用户删掉的参数不动，用户调过的值一律保留。
    """
    import json
    try:
        proj = json.loads(read(SRC_JSON))
    except Exception as e:
        print("✘ 工程版参数表 JSON 非法:", str(e)[:200])
        return False

    if not os.path.isfile(DST_JSON):
        os.makedirs(os.path.dirname(DST_JSON), exist_ok=True)
        shutil.copy2(SRC_JSON, DST_JSON)
        print("✔ 游戏版不存在，首次推送完整参数表")
        return True

    try:
        game = json.loads(read(DST_JSON))
    except Exception as e:
        print("✘ 游戏版参数表损坏，用工程版重建（用户值会丢）:", str(e)[:150])
        shutil.copy2(SRC_JSON, DST_JSON)
        return True

    game_keys = set()
    for g in game.get("groups", []):
        for x in g.get("parameters", []):
            game_keys.add(x.get("key"))

    added = []
    game_groups = {g.get("name"): g for g in game.get("groups", [])}
    for pg in proj.get("groups", []):
        name = pg.get("name")
        gg = game_groups.get(name)
        if gg is None:
            game.setdefault("groups", []).append(pg)
            for x in pg.get("parameters", []):
                added.append(x.get("key"))
            continue
        for x in pg.get("parameters", []):
            k = x.get("key")
            if k and k not in game_keys:
                gg.setdefault("parameters", []).append(x)
                game_keys.add(k)
                added.append(k)

    for meta in ("version", "title", "hotkey"):
        if meta in proj:
            game[meta] = proj[meta]

    if not added:
        print("✔ 参数表无需更新（游戏版已有全部参数，用户值全部保留）")
        return True

    io.open(DST_JSON, "w", encoding="utf-8", newline="\n").write(
        json.dumps(game, ensure_ascii=False, indent=2) + "\n")
    print("✔ 参数表已增量更新：新增 %d 项（%s）"
          % (len(added), ", ".join(added[:6]) + ("…" if len(added) > 6 else "")))
    print("  用户已调的值和开关状态全部保留")
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]

    if cmd == "diff":
        try:
            ja = read(SRC_JSON)
            jb = read(DST_JSON) if os.path.isfile(DST_JSON) else ""
            print("✔ 参数表一致" if ja == jb else
                  "✘ 参数表不一致（工程 %d 字节 / 游戏 %d 字节）" % (len(ja), len(jb)))
        except Exception as e:
            print("参数表对比失败:", e)

        same, differ, only_proj, only_game = 0, [], [], []
        src_set = set(lua_files(SRC_ROOT))
        dst_set = set(lua_files(DST_ROOT)) if os.path.isdir(DST_ROOT) else set()
        for rel in sorted(src_set):
            a = os.path.join(SRC_ROOT, rel)
            b = os.path.join(DST_ROOT, rel)
            if not os.path.isfile(b):
                only_proj.append(rel)
            elif filecmp.cmp(a, b, shallow=False):
                same += 1
            else:
                differ.append(rel)
        for rel in sorted(dst_set - src_set):
            only_game.append(rel)

        print("Lua 文件：一致 %d / 有差异 %d / 仅工程 %d / 仅游戏 %d"
              % (same, len(differ), len(only_proj), len(only_game)))
        for r in differ:
            print("  [差异] " + r)
        for r in only_proj:
            print("  [仅工程] " + r)
        for r in only_game:
            print("  [仅游戏] " + r)
        return 0

    if cmd == "push":
        ok, bad = check_lua_dir(SRC_ROOT)
        if not ok:
            print("✘ 工程版语法错误，拒绝推送:")
            for b in bad:
                print("  " + b)
            return 1

        n = 0
        for rel in lua_files(SRC_ROOT):
            s = os.path.join(SRC_ROOT, rel)
            d = os.path.join(DST_ROOT, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            if os.path.isfile(d) and filecmp.cmp(s, d, shallow=False):
                continue
            shutil.copy2(s, d)
            n += 1
        print("✔ 已推送 %d 个 Lua 文件（共 %d 个）" % (n, len(lua_files(SRC_ROOT))))

        # 清理：游戏侧有、工程侧没有的 .lua —— 那些是被删掉的旧模块，
        # 留着会被 require 到，或者被 UE4SS 当成残留。
        src_set = set(lua_files(SRC_ROOT))
        removed = []
        for rel in lua_files(DST_ROOT):
            if rel not in src_set:
                os.remove(os.path.join(DST_ROOT, rel))
                removed.append(rel)
        if removed:
            print("✔ 已删除游戏侧多余文件 %d 个：%s" % (len(removed), ", ".join(removed)))

        push_json()
        return 0

    if cmd == "pull":
        ok, bad = check_lua_dir(DST_ROOT)
        if not ok:
            print("✘ 游戏版语法错误，拒绝拉取:")
            for b in bad:
                print("  " + b)
            return 1
        n = 0
        for rel in lua_files(DST_ROOT):
            s = os.path.join(DST_ROOT, rel)
            d = os.path.join(SRC_ROOT, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            if os.path.isfile(d) and filecmp.cmp(s, d, shallow=False):
                continue
            shutil.copy2(s, d)
            n += 1
        print("✔ 已拉取 %d 个 Lua 文件" % n)
        if os.path.isfile(DST_JSON):
            shutil.copy2(DST_JSON, SRC_JSON)
            print("✔ 已拉取 pbz_tweaker.json")
        return 0

    print("未知命令:", cmd)
    return 1


if __name__ == "__main__":
    sys.exit(main())
