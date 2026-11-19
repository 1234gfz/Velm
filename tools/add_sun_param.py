# -*- coding: utf-8 -*-
"""给参数表加「平行光强度」一个参数（比例语义，1.0 = 100%）。

安全约束（踩过的坑）：
- 只**追加**新参数，绝不修改任何现有参数的 value / enabled。
- 加完后按 SUB_ORDER 重排，保证每个 sub 只出现一段连续块
  （面板是按「连续 sub」切段的，追加到末尾会产生第二个同名分组）。
- 改完先校验：所有原有参数的 value/enabled 必须和改之前完全一致。
"""
import io
import json
import collections
import os
import shutil

GAME = "E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZFog/pbz_tweaker.json"
PROJ = "E:/MSHY_Workbench/其他/影之刃零插件/lua/PBZFog/pbz_tweaker.json"

SUB_ORDER = ["白平衡", "天光", "阳光", "自动曝光", "环境光", "局部曝光", "色调", "色调分离"]


def snapshot(d):
    """记录所有参数的 value/enabled，用于改完比对。"""
    snap = {}
    for g in d["groups"]:
        for p in g.get("parameters", []):
            snap[p["key"]] = (json.dumps(p.get("value"), sort_keys=True), p.get("enabled"))
    return snap


def main():
    with io.open(GAME, encoding="utf-8") as f:
        d = json.load(f, object_pairs_hook=collections.OrderedDict)

    before = snapshot(d)

    grp = None
    for g in d["groups"]:
        if g["name"] == "光照与色调":
            grp = g
            break
    assert grp, "找不到光照与色调组"

    existing = {p["key"] for p in grp["parameters"]}

    if "sun.intensity" in existing:
        print("已存在 sun.intensity，跳过")
        return 0

    param = collections.OrderedDict([
        ("key", "sun.intensity"),
        ("label", "平行光强度"),
        ("type", "float"),
        ("min", 0),
        ("max", 3),
        ("step", 0.05),
        ("default", 1.0),
        ("value", 1.0),
        ("handler", "light"),
        ("hint",
         "场景主太阳（DirectionalLight）的强度倍率，1.0 = 100%（原始亮度），"
         "0.5 = 一半，2.0 = 两倍。和雾的浓度比例是同一套语义。"
         "只作用于主光——场景里通常有 3 个方向光组件（Ultra Dynamic Sky 的太阳/月亮/补光），"
         "强度为 0 的是没启用的，这里会自动锁定强度最大的那个主太阳，并持续跟踪；"
         "换关卡后重新锁定。关掉开关会还原成 100%。"
         "注意：这个场景的实际亮度还有一部分来自天光（SkyLight），只调这个可能不足以完全压暗/提亮。"),
        ("enabled", False),
        ("sub", "阳光"),
    ])
    grp["parameters"].append(param)

    # 按 SUB_ORDER 重排，保证 sub 连续（面板按连续 sub 切段）
    by_sub = {s: [] for s in SUB_ORDER}
    others = []
    for x in grp["parameters"]:
        s = x.get("sub", "")
        (by_sub[s] if s in by_sub else others).append(x)
    grp["parameters"] = others + [x for s in SUB_ORDER for x in by_sub[s]]

    # 校验：原有参数的 value/enabled 必须一字未变
    after = snapshot(d)
    bad = []
    for k, v in before.items():
        if k in after and after[k] != v:
            bad.append((k, v, after[k]))
    if bad:
        print("✘ 原有参数被改动，中止写入：")
        for k, a, b in bad:
            print("   ", k, a, "→", b)
        return 1

    # 校验：sub 序列无重复块
    seq = [x.get("sub", "(无)") for x in grp["parameters"]]
    blocks = []
    for s in seq:
        if not blocks or blocks[-1] != s:
            blocks.append(s)
    dups = [s for s in set(seq) if blocks.count(s) > 1]
    if dups:
        print("✘ sub 出现重复块：", dups)
        return 1

    shutil.copy2(GAME, GAME + ".bak-before-sun")

    tmp = GAME + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    os.replace(tmp, GAME)

    # 同步回工程版（游戏版是用户数据的真相）
    shutil.copy2(GAME, PROJ)

    print("✔ 已加入 sun.intensity")
    print("  sub 顺序:", " → ".join(blocks))
    print("  总参数:", sum(len(g.get("parameters", [])) for g in d["groups"]))
    print("  原有参数 value/enabled 全部未变（已校验）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
