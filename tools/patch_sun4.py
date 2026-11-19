# -*- coding: utf-8 -*-
"""给 lightProbe 的 restore 命令加上「清空引擎基准」。

问题：restore 只把光强写回原值，但 engineStep 的 ratio 基准还在内存/文件里，
下一轮就按旧基准再写一次，等于没还原。

修法：restore 时一并清掉 Engine.base / Engine.written 和落盘文件，
让 engineStep 下一轮从干净的当前值重新取基准。
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lua", "PBZFog", "Scripts", "main.lua")


def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()


def write_atomic(p, text):
    tmp = p + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if len(read(tmp)) != len(text):
        raise RuntimeError("write mismatch")
    os.replace(tmp, p)


def main():
    s = read(SRC)
    old = """        lightState = nil
        log("光照：全部还原完成")
        return"""
    new = """        -- 关键：把引擎参数的基准也清掉。
        -- 只还原数值、不清基准的话，engineStep 下一轮会按旧基准再写回去，
        -- 等于白还原（实测过：还原成 3.0 后立刻被写回 6.0）。
        Engine.base["sun.intensity"] = nil
        Engine.written["sun.intensity"] = nil
        os.remove("E:/PBZ_engine_state.txt")
        lightState = nil
        log("光照：全部还原完成，引擎基准已清空")
        return"""
    if old not in s:
        print("✘ 锚点未匹配")
        return 1
    s = s.replace(old, new, 1)
    write_atomic(SRC, s)
    print("✔ restore 已清基准，共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
