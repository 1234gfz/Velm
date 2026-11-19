#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""启动游戏，带 Steam 就绪检查。

为什么要这个脚本：
  实测 Steam 在游戏退出后需要几秒到几十秒做收尾工作，这段时间里
  发 `steam://rungameid/...` 启动请求会被静默忽略 —— 表现为「游戏没反应」。
  很容易误判成 DLL 崩溃或代码问题（踩过这个坑，浪费了不少时间）。

  这个脚本会反复尝试启动，直到游戏进程真的出现为止。

用法：
  python tools/launch.py            # 启动并等到进程出现
  python tools/launch.py --wait-scene  # 启动后等 Lua 报告已进入场景
"""

import argparse
import os
import subprocess
import sys
import time

APPID = "4115450"   # Phantom Blade Zero
LOG = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log"
TRACE = r"E:/PBZNative_trace.log"


def pbz_running():
    r = subprocess.run(["tasklist"], capture_output=True, text=True, errors="ignore")
    return "PBZ.exe" in r.stdout


EXE = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/PBZ.exe"


def launch_once():
    """优先直接启动 exe，失败再退回 Steam 协议。

    实测直接跑 PBZ.exe 完全可行 —— Steam 的 DRM 只在首次启动时校验，
    之后直接运行不需要 Steam 介入。好处是**瞬间启动**，
    不用等 Steam 那 25 秒收尾（那个等待期发启动请求会被静默忽略，
    之前误判成 DLL 崩溃的就是这个）。
    """
    if os.path.isfile(EXE):
        try:
            # DETACHED_PROCESS：让游戏独立于本进程运行，脚本退出后游戏继续
            subprocess.Popen([EXE], cwd=os.path.dirname(EXE),
                             creationflags=0x00000008 | 0x00000200,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except Exception as e:
            print(f"  直接启动失败（{e}），改用 Steam")
    subprocess.run(["cmd", "/c", "start", "", f"steam://rungameid/{APPID}"],
                   capture_output=True)


def wait_for(pred, timeout, label, interval=1.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            return True, time.time() - t0
        time.sleep(interval)
    return False, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wait-scene", action="store_true", help="等到进入场景")
    ap.add_argument("--attempts", type=int, default=5, help="最多尝试几次启动")
    ap.add_argument("--restart", action="store_true",
                    help="关掉正在运行的游戏再启动（默认不会杀）")
    a = ap.parse_args()

    # 启动前清理：残留进程会让「进程出现」的判定失真（会误判成秒启动），
    # 而残留的命令文件里存的是上一次启动的对象地址，新进程读到就是无效内存。
    #
    # 但**默认不杀正在运行的游戏** —— 只有显式 --restart 才杀。
    # 踩过的坑：脚本擅自 taskkill，把用户正在玩的游戏杀掉了，还以为是游戏自己崩的。
    if pbz_running():
        if not a.restart:
            print("游戏已在运行。如需重启请加 --restart（我不会擅自关你的游戏）")
            return 0
        print("按 --restart 要求，先关掉现有进程")
        subprocess.run(["taskkill", "/F", "/IM", "PBZ.exe"], capture_output=True)
        time.sleep(2)
    for f in (r"E:/PBZNative_cmd.txt", r"E:/PBZNative_trace.log"):
        try:
            if os.path.isfile(f):
                os.remove(f)
        except Exception:
            pass

    if pbz_running():
        print("游戏已在运行，跳过启动")
    else:
        for n in range(1, a.attempts + 1):
            print(f"启动尝试 {n}/{a.attempts} …")
            launch_once()
            ok, dt = wait_for(pbz_running, 15, "进程出现")
            if ok:
                # 进程出现 ≠ 启动成功。要再观察几秒确认没退出
                # （踩过：0.7 秒出现、5 秒后消失，被误判成「秒启动成功」）。
                time.sleep(6)
                if pbz_running():
                    print(f"✔ 游戏已启动并稳定（{dt:.0f}s 出现）")
                    break
                print("  进程出现后又退出了，重试")
                continue
            print(f"  这次没起来（{dt:.0f}s），等一会儿重试")
            time.sleep(8)
        else:
            print("✘ 多次尝试都没启动，检查 Steam 是否正常")
            return 1

    # 等 C++ 线程打出 FOUND（说明拿到场景对象了）
    if a.wait_scene:
        print("等待进入场景（最多 180s）…")

        def has_found():
            if not os.path.isfile(TRACE):
                return False
            try:
                with open(TRACE, "r", encoding="utf-8", errors="ignore") as f:
                    return "FOUND" in f.read()
            except Exception:
                return False

        ok, dt = wait_for(has_found, 180, "场景对象", interval=2.0)
        if ok:
            print(f"✔ 已拿到场景对象（{dt:.0f}s）")
            with open(TRACE, "r", encoding="utf-8", errors="ignore") as f:
                for ln in f.read().splitlines():
                    if "FOUND" in ln or "vt=" in ln:
                        print("   " + ln)
        else:
            print("⚠ 超时，可能还停在主菜单")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
