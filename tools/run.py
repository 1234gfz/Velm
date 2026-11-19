#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""一键：等重载 → 触发诊断开关 → 等结果 → 复位 → 打印日志。

把原来「改JSON / sleep 28 / 改JSON / sleep 8 / grep」五步压成一条命令，
且不用固定 sleep —— 盯着日志标记走，该等多久等多久。

用法：
  python tools/run.py --tag "SDK："                 # 触发 testCube 并等 "SDK：" 出现
  python tools/run.py --tag "加组件：" --wait-reload  # 先等热重载完成再触发
  python tools/run.py --tag "真网格：" --lines 12     # 命中后打印最后 12 条相关日志
"""

import argparse
import io
import json
import os
import sys
import time

UE4SS = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss"
CFG = os.path.join(UE4SS, "Mods/PBZFog/pbz_tweaker.json")
LOG = os.path.join(UE4SS, "UE4SS.log")

RELOAD_MARK = "v3 loaded"


def read_cfg():
    return json.load(io.open(CFG, encoding="utf-8"))


def write_cfg(d):
    io.open(CFG, "w", encoding="utf-8", newline="\n").write(
        json.dumps(d, ensure_ascii=False, indent=2) + "\n")


def log_text():
    try:
        with io.open(LOG, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return ""


def wait_for(pred, timeout, interval=0.4, label=""):
    """等 pred() 返回 True。返回 (是否成功, 耗时)。"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            return True, time.time() - t0
        time.sleep(interval)
    return False, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="等日志出现这段文字")
    ap.add_argument("--key", default="testCube", help="用哪个开关触发（默认 testCube）")
    ap.add_argument("--wait-reload", action="store_true", help="先等热重载完成")
    ap.add_argument("--reload-timeout", type=float, default=25.0)
    ap.add_argument("--timeout", type=float, default=20.0, help="触发后等结果秒数")
    ap.add_argument("--lines", type=int, default=10, help="命中后打印多少条相关日志")
    ap.add_argument("--grep", help="打印时额外过滤的关键字（默认用 --tag）")
    a = ap.parse_args()

    # 1) 等热重载（只在需要时）
    if a.wait_reload:
        base = log_text()
        base_count = base.count(RELOAD_MARK)
        ok, dt = wait_for(lambda: log_text().count(RELOAD_MARK) > base_count,
                          a.reload_timeout, label="reload")
        if ok:
            print("✔ 热重载完成（%.1fs）" % dt)
        else:
            print("⚠ 等热重载超时 %.1fs，继续尝试触发" % a.reload_timeout)

    # 2) 触发。先把开关关掉再打开，确保模组一定能检测到「从 false 变 true」
    d = read_cfg()
    if d.get(a.key):
        d[a.key] = False
        write_cfg(d)
        time.sleep(0.8)

    # 关键：以「触发这一刻」的日志长度为基准，只认之后新增的内容。
    # 否则日志里已有的旧结果会让判定瞬间命中，读到上一次的数据。
    base_len = len(log_text())

    d = read_cfg()
    d[a.key] = True
    write_cfg(d)
    print("→ 已触发 %s，等 %r …" % (a.key, a.tag))

    def found():
        text = log_text()
        return text[base_len:].count(a.tag) > 0

    # 4) 等结果（只看触发后新增的日志）
    ok, dt = wait_for(found, a.timeout)
    if ok:
        print("✔ 结果已出现（%.1fs）" % dt)
    else:
        print("✘ 超时 %.1fs 没等到 %r" % (a.timeout, a.tag))

    # 5) 立刻复位，避免下次启动自动跑
    d = read_cfg()
    d[a.key] = False
    write_cfg(d)

    # 6) 打印相关日志（只看触发之后的部分）
    text = log_text()[base_len:]
    kw = a.grep or a.tag
    lines = [ln for ln in text.splitlines() if kw in ln]
    if lines:
        print("\n--- 最近 %d 条含 %r 的日志 ---" % (min(a.lines, len(lines)), kw))
        for ln in lines[-a.lines:]:
            # 去掉时间戳前缀，保留 [PBZ] 之后的内容
            i = ln.find("[PBZ]")
            print("  " + (ln[i + 5:].strip() if i >= 0 else ln.strip())[:200])
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
