# PBZVisualTweaker

> 《影之刃零》(Phantom Blade Zero) 画面调参模组：治好近景「黑乎乎、雾蒙蒙」，可细调雾 / 后处理 / 光照，带面板与预设。纯脚本/反射修改**单机**画面参数，不含任何游戏资源、不涉及破解。

## 功能
- **雾效**：整体浓度、体积雾起始距离/淡入（专治房间近处浓雾糊脸）、局部雾团开关
- **画面**：泛光、色散、耀斑、颗粒、暗角、拖影
- **光照与色调**：白平衡、阳光强度、曝光与测光、局部曝光、色调映射（胶片曲线）、色彩调色、环境光/遮蔽
- **三种调节模式**（逐参数）：`绝对`（直接给一个值）/ `比例`（原值 × %，对场景自适应）/ `偏移`（原值 + Δ）
- 面板内置托盘图标、F8 呼出、可保存/切换**预设**

## 组成
| 组件 | 说明 |
|---|---|
| `PBZFog` | UE4SS Lua 模组（核心） |
| `PBZTweaker` | WPF 调参面板（F8 / 系统托盘） |
| `PBZModManager` | 安装 / 检测修复 / 卸载 管理器（独立 exe） |

## 安装
### 方式 A：管理器（窗口版 / 命令行）
**窗口版（推荐）**：双击 `PBZModManager.exe`（与 `PBZFog` 文件夹同层）→「自动检测」或选游戏目录 → 勾选「使用自带 UE4SS」（选解压目录）或「使用我已安装的 UE4SS」→ 点「安装 / 修复」。

**命令行版**：
```powershell
# 查看状态（自动定位 Steam 库，也可 --game 指定 "…\platform\steam"）
PBZModManager.exe status

# 安装：用自带 UE4SS（--ue4ss 指向解压目录，含 ue4ss\UE4SS.dll 与 dwmapi.dll）
PBZModManager.exe install --ue4ss "…\ue4ss自带包"
# 或：使用你已装的 UE4SS
PBZModManager.exe install --use-own-ue4ss

# 卸载
PBZModManager.exe uninstall
```
管理器会：检测代理 DLL 冲突（`dwmapi.dll`/`version.dll`/`dxgi.dll`，冲突时需 `--force-proxy` 确认）、改前**自动备份**、拷贝模组、在 `mods.txt` 加 `PBZFog : 1`；**游戏运行时会拒绝改动**。

### 方式 B：手动
1. 确保游戏已安装 [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)（推荐版本见 Releases）。
2. 把 `PBZFog` 文件夹放进 `<游戏>\platform\steam\ue4ss\Mods\`。
3. 打开 `ue4ss\Mods\mods.txt`，加一行 `PBZFog : 1`。
4. 进游戏后按 **F8** 呼出面板（或点系统托盘的圆点图标）。

## 使用
- **F8 / 托盘图标**：显示或隐藏面板。
- 顶部**总开关**：一键开/关全部画面增强（关掉即回到游戏原版，数值都保留）。
- 每个参数左侧的小图标切换模式：`=` 绝对 / `%` 比例 / `±` 偏移。
- **分辨率/窗口**不受总开关影响，单独设置，方便对比效果时不闪屏。
- 面板可保存多套**预设**，切场景/换风格一键套用。

## 常见问题
- **游戏打不开 / 启动后闪退**：八成是代理 DLL 冲突（同时存在多个 `dwmapi/version/dxgi.dll`）。用管理器「检测修复」，或手动只保留一套。
- **参数调了没反应**：部分参数依赖画质档位（如 Lumen 相关需要高档位）；确认顶部总开关是开着的。
- **杀软误报**：未签名 exe + 注入行为常见误报，请添加信任；有能力的可自行校验 Releases 里的哈希。
- **游戏更新后失效**：模组依赖游戏内部类/属性，大版本更新可能失效。看 Releases 是否已更新。

## 构建 / 开发
```powershell
# 跑离线测试（需要本机 Lua 5.4；可设 $env:LUA_EXE）
powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1

# 生成可发布目录 _release\PBZFog
powershell -ExecutionPolicy Bypass -File tools\package_release.ps1
```
详见 [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)、[docs/TESTING.md](docs/TESTING.md)。

## 许可证
本仓库代码采用 MIT，见 [LICENSE](LICENSE)。随包第三方组件（如 UE4SS）各自遵循其许可（随包附其 LICENSE/NOTICE）。

## 免责声明
仅用于**单机**画面调整。使用风险自负；游戏更新可能导致失效，请关注 Releases。
