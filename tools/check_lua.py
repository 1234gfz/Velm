#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""改完 main.lua 必须跑这个。用真正的 Lua 解析器，不是正则。
之前踩过的坑：手写的括号/关键字计数检查放过了 `#` 当注释的笔误，
导致脚本静默加载失败，排查浪费了半小时。
"""
import io
import sys

MOD = "E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZFog/Scripts/main.lua"


def main(path=MOD):
    from luaparser import ast
    src = io.open(path, encoding="utf-8").read()
    try:
        ast.parse(src)
    except Exception as e:
        print("✘ Lua 语法错误：")
        print(str(e)[:900])
        return 1
    print("✔ Lua 语法校验通过（%d 行）" % len(src.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else MOD))
