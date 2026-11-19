# UE4SS 推荐包（第三方，MIT）

本模组依赖 [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) 注入 Lua 运行时。为降低“版本对不上”的坑，发布包可**内置一份固定版本**的 UE4SS。

## 固定版本
- **UE4SS `v3.0.1`（Beta #0，Git SHA `#f885e8d2`）** —— 本模组实测通过的版本。
- 许可证：MIT。随包必须附 UE4SS 的 `LICENSE`（见上游仓库）。

## 布局（v3.0.x）
```
<游戏>\platform\steam\
├─ dwmapi.dll              ← UE4SS 注入代理（放在有 PBZ.exe 的目录）
└─ ue4ss\
   ├─ UE4SS.dll
   ├─ UE4SS-settings.ini   ← 推荐配置（见下）
   └─ Mods\
      ├─ mods.txt
      └─ Velm\           ← 本模组
```
> ⚠ 注意：UE4SS **v4.0.0 起改了布局**（所有文件都进 `ue4ss\` 子目录，只有 `dwmapi.dll` 留在 exe 同目录）。本包 pin 的是 v3.0.1（旧布局）。若日后升级到 4.x，安装器与 `Mods` 路径要同步调整。

## 推荐 UE4SS-settings.ini 关键项
- `[EngineVersionOverride] MajorVersion=5 MinorVersion=7`
- `[Hooks]` 全套开启（`HookProcessInternal/HookLoadMap/HookBeginPlay/HookAActorTick/HookEngineTick/HookUObjectProcessEvent/HookUStructLink` 等）
- `[Debug] ConsoleEnabled=0 / GuiConsoleEnabled=0`（普通用户不需要控制台）
- `[CrashDump] EnableDumping=1 FullMemoryDump=0`

## 获取（维护者）
```powershell
powershell -ExecutionPolicy Bypass -File tools\fetch_ue4ss.ps1 `
    -Url "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip" `
    -Sha256 "4b47d4bceddd2f561a4e395bfa00924ccfc945af576a2d0c613e6537846c57ec" `
    -Proxy "http://127.0.0.1:7897" `
    -LicenseUrl "https://raw.githubusercontent.com/UE4SS-RE/RE-UE4SS/v3.0.1/LICENSE"
```
下载解压到 `vendor\ue4ss\`（已被 `.gitignore` 忽略，不进 git）。**二进制造包时再放，源码仓库不存二进制。**

> 实测记录（2026-11-19）：官方 `v3.0.1` release 包 `UE4SS_v3.0.1.zip` 大小 5,523,402 字节，SHA256 = `4b47d4bceddd2f561a4e395bfa00924ccfc945af576a2d0c613e6537846c57ec`，内含 `UE4SS.dll`(16,263,680B)、`dwmapi.dll`(58,368B)、`UE4SS-settings.ini`、`Mods\`。
> 注意：作者本机验证所用的是 `v3.0.1 Beta #0 / Git SHA f885e8d2` 构建（`UE4SS.dll` 20,698,112B，与官方 release 包不同体积，属不同构建）。公开包默认附带**官方 v3.0.1 release**；若个别环境有兼容问题，管理器支持「使用我已安装的 UE4SS」改用你本机能用的那份。

## 代理 DLL 冲突检测
UE4SS 的 `dwmapi.dll` 常与 ReShade 的 `dxgi.dll`、DLSS 帧生成的 `version.dll` 等注入代理冲突。安装前用：
```powershell
powershell -ExecutionPolicy Bypass -File tools\check_proxies.ps1 -GameSteamDir "<游戏>\platform\steam"
```
同时存在多个代理时，只保留需要的（UE4SS 必须有 `dwmapi.dll`）。
