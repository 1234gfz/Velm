#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""编译 PBZNative.dll 并安装到游戏。

不用 CMake —— 单个 DLL 直接调 cl.exe/link.exe 就够了，省掉整个 CMake 依赖。

为什么不用 CMake：
  UE4SS 官方的 CMake 流程要求 clone 整个 RE-UE4SS 并拉 Unreal 伪代码 submodule
  （UEPseudo，需要 Epic 账号授权）。我们绕开了：
    - UE4SS 头文件用 sparse checkout 只拉需要的部分（4.9MB，无需授权）
    - GUI 依赖用 include_patch/GUI/GUITab.hpp 切断（原版为拿 StringType
      引入了整个 GUI 树，纯属多余）
    - 导入库从 UE4SS.dll 的导出表直接生成（deps/ue4ss-lib/UE4SS.lib）
    - SDK 头文件从游戏里 GenerateSDK 生成（tools/gen_sdk.py）

用法：
  python tools/build.py           # 编译 + 安装
  python tools/build.py --no-install
"""

import os
import subprocess
import sys
import time

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CPP = os.path.join(PROJ, "cpp")
SRC = os.path.join(CPP, "src", "dllmain.cpp")
OUT_DLL = os.path.join(CPP, "PBZNative.dll")

GAME = r"E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss"
INSTALL_DIR = os.path.join(GAME, "Mods", "PBZNative", "dlls")

MSVC = r"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.43.34808"
SDK_INC = r"C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0"
SDK_LIB = r"C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0"

DEPS = os.path.join(CPP, "deps", "RE-UE4SS", "deps", "first")

INCLUDES = [
    "include_patch",                        # 必须第一，切断 GUI 依赖
    "deps/RE-UE4SS/UE4SS/include",
    "deps/third_party",
    "deps/RE-UE4SS/deps/first/File/include",
    "deps/RE-UE4SS/deps/first/DynamicOutput/include",
    "deps/RE-UE4SS/deps/first/Constructs/include",
    "deps/RE-UE4SS/deps/first/Helpers/include",
    "deps/RE-UE4SS/deps/first/JSON/include",
    "deps/RE-UE4SS/deps/first/ParserBase/include",
    "deps/RE-UE4SS/deps/first/LuaMadeSimple/include",
    "deps/RE-UE4SS/deps/first/LuaRaw/include",
    "deps/RE-UE4SS/deps/first/Function/include",
    "deps/RE-UE4SS/deps/first/IniParser/include",
    "deps/RE-UE4SS/deps/first/Input/include",
    "deps/RE-UE4SS/deps/first/Profiler/include",
    "deps/RE-UE4SS/deps/first/ScopedTimer/include",
    "deps/RE-UE4SS/deps/first/SinglePassSigScanner/include",
    "deps/RE-UE4SS/deps/first/MProgram/include",
    # 生成的 SDK（Engine / CoreUObject 等），写引擎代码时用
    "sdk/UHTHeaderDump/Engine/Public",
    "sdk/UHTHeaderDump/CoreUObject/Public",
]


def run(cmd, cwd, env):
    print("  $", " ".join(cmd[:4]), "…")
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="ignore")
    out = (r.stdout or "") + (r.stderr or "")
    for ln in out.splitlines():
        if "error" in ln.lower() or "fatal" in ln.lower() or "warning C" in ln:
            print("   ", ln.strip()[:180])
    return r.returncode


def main():
    install = "--no-install" not in sys.argv

    env = dict(os.environ)
    env["INCLUDE"] = ";".join([f"{MSVC}\\include", f"{SDK_INC}\\ucrt",
                               f"{SDK_INC}\\shared", f"{SDK_INC}\\um", f"{SDK_INC}\\winrt"])
    env["LIB"] = ";".join([f"{MSVC}\\lib\\x64", f"{SDK_LIB}\\ucrt\\x64", f"{SDK_LIB}\\um\\x64"])
    env["Path"] = f"{MSVC}\\bin\\Hostx64\\x64;" + env.get("Path", "")

    obj = os.path.join(CPP, "build.obj")
    os.makedirs(os.path.dirname(obj), exist_ok=True)

    # 编译（用绝对路径，避免 PATH 在不同 shell 下不一致）
    cl = os.path.join(MSVC, "bin", "Hostx64", "x64", "cl.exe")
    # /MD 是关键：UE4SS.dll 用的是动态 CRT（MSVCP140.dll / VCRUNTIME140.dll），
    # mod 必须用同一套，否则跨 DLL 传 std::string 会崩。
    # cl 默认是 /MT（静态 CRT），不匹配就会在加载后立刻退出。
    cmd = [cl, "/nologo", "/std:c++latest", "/EHa", "/utf-8", "/MD", "/c",
           SRC, f"/Fo:{obj}"]
    for i in INCLUDES:
        if os.path.isdir(os.path.join(CPP, i)):
            cmd.insert(-2, f"/I{i}")
    print("编译…")
    rc = run(cmd, CPP, env)
    if rc != 0:
        print("✘ 编译失败 (rc=%d)" % rc)
        return 1
    print("✔ 编译通过")

    # 链接
    print("链接…")
    lnk = os.path.join(MSVC, "bin", "Hostx64", "x64", "link.exe")
    cmd = [lnk, "/nologo", "/DLL", f"/OUT:{OUT_DLL}", obj,
           "/LIBPATH:deps/ue4ss-lib", "UE4SS.lib"]
    rc = run(cmd, CPP, env)
    if rc != 0:
        print("✘ 链接失败 (rc=%d)" % rc)
        return 1
    size = os.path.getsize(OUT_DLL)
    print("✔ 链接通过：PBZNative.dll (%.1f KB)" % (size / 1024))

    # 安装：DLL 在游戏运行时被锁住，覆盖不了。
    #
    # 注意：绝对不要自动杀游戏！之前这里加了 taskkill /F /IM PBZ.exe，
    # 结果用户在游戏里玩着，我跑一次编译就把游戏杀掉了 —— 用户以为是游戏自己崩的，
    # 白查了半天。现在改成：只在确实被锁住时才提示，由用户自己决定关不关。
    if install:
        os.makedirs(INSTALL_DIR, exist_ok=True)
        # UE4SS 把路径写死成 dlls\main.dll（见 CppMod.cpp），
        # 所以安装时必须改名，不能叫 PBZNative.dll
        dst = os.path.join(INSTALL_DIR, "main.dll")
        import shutil
        try:
            shutil.copy2(OUT_DLL, dst)
            print("✔ 已安装到", dst)
        except PermissionError:
            print("\n⚠ DLL 被占用 —— 游戏正在运行，关掉游戏后再装。")
            print("   我没有自动关游戏（那样会打断你）。装好后重新启动游戏即可。")
            print("   编译产物已就绪：", OUT_DLL)
            return 3
        print("\n提示：C++ mod 只在游戏启动时加载，改完必须重启游戏。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
