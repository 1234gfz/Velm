#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""等日志出现新内容就返回，替代固定 sleep。

固定 sleep 30 秒的问题是：热重载可能 5 秒就好了，也可能 60 秒没好。
死等要么浪费时间，要么等不够。这个脚本盯着日志文件，等到出现指定标记就立刻返回。

用法：
  python tools/wait_log.py --tail "SDK："            # 等日志出现 "SDK：" 就返回
  python tools/wait_log.py --grow                    # 等日志变大（任意新内容）
  python tools/wait_log.py --grow --timeout 20       # 最多等 20 秒
  python tools/wait_log.py --tail "Error loading" --since 0   # 从头找
"""

import argparse
import io
import os
import sys
import time

LOG = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=LOG)
    ap.add_argument("--tail", help="等到日志里出现这段文字")
    ap.add_argument("--grow", action="store_true", help="等到日志文件变大")
    ap.add_argument("--timeout", type=float, default=45.0, help="最长等待秒数")
    ap.add_argument("--interval", type=float, default=0.4, help="轮询间隔")
    ap.add_argument("--print", dest="do_print", action="store_true",
                    help="命中后打印匹配到的行")
    a = ap.parse_args()

    if not os.path.isfile(a.log):
        print("✘ 日志不存在:", a.log)
        return 1
    if not (a.tail or a.grow):
        print("✘ 需要 --tail 或 --grow")
        return 1

    start_size = os.path.getsize(a.log)
    start_time = time.time()
    deadline = start_time + a.timeout

    while time.time() < deadline:
        time.sleep(a.interval)
        if a.grow:
            size = os.path.getsize(a.log)
            if size > start_size:
                print("✔ 日志已更新 (+%d 字节，%.1fs)" % (size - start_size, time.time() - start_time))
                return 0
        if a.tail:
            # 只读文件末尾，避免整文件重读
            try:
                with io.open(a.log, "r", encoding="utf-8", errors="ignore") as f:
                    data = f.read()
            except Exception:
                continue
            idx = data.rfind(a.tail)
            if idx >= 0:
                if a.do_print:
                    line_start = data.rfind("\n", 0, idx) + 1
                    line_end = data.find("\n", idx)
                    line = data[line_start:line_end if line_end > 0 else len(data)]
                    print("✔ 命中（%.1fs）: %s" % (time.time() - start_time, line.strip()[:200]))
                else:
                    print("✔ 命中 %r（%.1fs）" % (a.tail, time.time() - start_time))
                return 0

    print("✘ 超时 %.1fs 未等到" % a.timeout)
    return 2


if __name__ == "__main__":
    sys.exit(main())
