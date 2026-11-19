#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""从游戏里生成 C++ SDK 头文件，并同步到工程。

原理：UE4SS.dll 内置完整的 SDKGenerator（DLL 里有 SDKGenerator::generate /
compute_struct_layouts 等符号），Lua 侧暴露为全局函数 GenerateSDK。
调用它就能从「当前运行的游戏」生成 UHT 兼容头文件 —— 不需要 Epic 账号，
不需要 Unreal 源码授权，不需要 clone RE-UE4SS。

产出两个目录（都在游戏 ue4ss 根目录下）：
  UHTHeaderDump/    UHT 兼容头文件，按模块分目录（Engine/Public/Actor.h 等）
  CXXHeaderDump/    扁平 C++ 头文件，主要是蓝图类

用法：
  python tools/gen_sdk.py            # 触发游戏生成，然后同步到 cpp/sdk/
  python tools/gen_sdk.py --sync     # 只同步（游戏已生成过）
"""

import argparse
import io
import json
import os
import shutil
import sys
import time

UE4SS = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss"
MOD = os.path.join(UE4SS, "Mods/PBZFog")
CFG = os.path.join(MOD, "pbz_tweaker.json")
SRC_UHT = os.path.join(UE4SS, "UHTHeaderDump")
SRC_CXX = os.path.join(UE4SS, "CXXHeaderDump")

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(PROJ, "cpp", "sdk")

# 只同步这几个核心模块，其它模块（游戏专有、插件）用不上，省体积
CORE_MODULES = ["Engine", "CoreUObject", "Core", "PhysicsCore",
                "RenderCore", "RHI", "InputCore", "SlateCore"]


def read_cfg():
    return json.load(io.open(CFG, encoding="utf-8"))


def write_cfg(d):
    io.open(CFG, "w", encoding="utf-8", newline="\n").write(
        json.dumps(d, ensure_ascii=False, indent=2) + "\n")


def trigger_generate():
    """把 testCube 开关拨一下，触发模组里的 SDK 生成分支。"""
    d = read_cfg()
    d["testCube"] = True
    write_cfg(d)
    print("已触发 GenerateSDK，等待生成（约 10 秒）…")
    time.sleep(10)
    d = read_cfg()
    d["testCube"] = False
    write_cfg(d)
    print("开关已复位")


def sync():
    if not os.path.isdir(SRC_UHT):
        print("✘ 找不到 %s，先在游戏里生成一次" % SRC_UHT)
        return 1

    if os.path.isdir(DST):
        shutil.rmtree(DST)
    os.makedirs(DST)

    total = 0
    for m in CORE_MODULES:
        src = os.path.join(SRC_UHT, m)
        if not os.path.isdir(src):
            print("  跳过（不存在）:", m)
            continue
        dst = os.path.join(DST, "UHTHeaderDump", m)
        shutil.copytree(src, dst)
        n = sum(len(f) for _, _, f in os.walk(dst))
        total += n
        print("  %-14s %d 个文件" % (m, n))

    # 蓝图类头文件也带上，写 C++ 时可能要用游戏自己的类
    if os.path.isdir(SRC_CXX):
        shutil.copytree(SRC_CXX, os.path.join(DST, "CXXHeaderDump"))
        n = sum(len(f) for _, _, f in os.walk(os.path.join(DST, "CXXHeaderDump")))
        print("  %-14s %d 个文件" % ("CXXHeaderDump", n))

    print("\n✔ 已同步到 %s（共 %d 个文件）" % (DST, total))

    # 验证关键头文件
    key = os.path.join(DST, "UHTHeaderDump", "Engine", "Public", "Actor.h")
    if os.path.isfile(key):
        print("✔ Actor.h 已就位")
    else:
        print("✘ Actor.h 缺失")
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sync", action="store_true", help="只同步，不触发生成")
    a = ap.parse_args()
    if not a.sync:
        trigger_generate()
    return sync()


if __name__ == "__main__":
    sys.exit(main())
