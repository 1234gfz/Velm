# PBZVisualTweaker — 开源发布计划（RELEASE PLAN）

> 记录所有已确认需求与工程约束，作为拆任务与验收的依据。改代码前先对照本文。

## 0. 背景与目标
- 《影之刃零》(Phantom Blade Zero) 单机 ARPG；玩家普遍抱怨近景「黑乎乎、雾蒙蒙」。
- 作者自制的调参方案：`PBZFog`（UE4SS Lua 模组，改雾/后处理/光照参数）+ `PBZTweaker`（WPF 面板）。已通关一周目实测可用。
- 目标：整理成**可公开分发、可长期维护**的开源项目，并附几套预设。

## 1. 产品形态（三件套，一个包发布）
- `PBZFog`：UE4SS Lua 模组（核心）。
- `PBZTweaker`：WPF 调参面板（F8 / 系统托盘）。
- `PBZModManager`：**独立** C# 管理器 exe（安装 / 检测修复 / 卸载 / 版本检测）。
- `presets/`：3~5 套预设（主题化）。

## 2. 参数表整理（本次核心）
### 2.1 删除（明确废弃 / 有害）
- `fog.clone` 接管雾（副本模式）
- `fog.freezeuds` 冻结 UDS
- `sky.intensity` 天光强度（实测无效）
- `gi.indirect` 间接光总倍率（Lumen 下无效）
- `gi.lumengi` Lumen 最终聚集质量
- `gi.lumenscene` Lumen 场景光照质量
- `cam.fov` 相机 FOV（切镜头会被覆盖）
- 顶层调试字段：`probe / testHideEasyFog / testMie / testFogRaw / testCloneRaw / testClonePos / testNoHide / testCube`
- **对应 handler 代码一并删**（clone / sky / uds / fov），不留死代码。

### 2.2 保留但默认隐藏 / 标「进阶」
- 枚举型：`img.bloommethod`、`gi.localexpmode`、`gi.evmode`
- 偏门：`gi.lekernel`、`gi.lehit`、`gi.lelot`、`gi.lehits`、`gi.lelos`、`gi.calconst`、`gi.histmax`

### 2.3 分组重排（「光照与色调」原 50 个，拆细）
- 雾效：整体强度(`fog.density/maxopacity/start`) + 体积雾(`extinction/heightfall/scatter/voldist/vstart/vnearfade`)
- 局部雾团：`lfog.visible`（并入雾效或单列，待定）
- 画面：泛光(`bloom/bloomthr/bloomsize/bloompfmax`) + 其他(`ca/flare/grain/vignette/mblur`)
- 光照与色调 → 拆成：**白平衡**(`gi.temp`) / **阳光**(`sun.intensity`) / **曝光与测光** / **局部曝光** / **色调映射·胶片** / **色彩调色** / **环境光·遮蔽**
- 分辨率（窗口）：`res.mode`

## 3. 关键工程要求（避免 bug 的硬约束）
### 3.1 去硬编码（必须）
- 现状写死：`core/env.lua:7` `MODDIR=E:/...`、`:14` `TWEAKER=C:/Users/MSHY03/...`、`:18-20` `E:/PBZ_*.txt`；`main.lua:20-23` `package.path`；面板 `MainWindow.xaml.cs:121`；`fog.lua:154` `E:/PBZ_fogdiag.txt`。
- 方案：`debug.getinfo(1,"S").source` 反推 `Scripts` 目录 → `MODDIR`；面板放 mod 内（`../PBZTweaker/PBZTweaker.exe`）；临时/状态文件放 mod 目录或 `%TEMP%`。

### 3.2 分辨率独立于总开关（master）
- 现状：master 关 → 全部按关闭处理（`schema.lua:68`），面板重应用 → 窗口变 → 黑屏。
- 方案：参数加 `ignoreMaster:true`（env/app 类）；master 只管画面增强类；分辨率**只在显式「应用」时生效**，master 切换/微调/重载都不碰。

### 3.3 性能不变量（保留已验证成果，别回归）
- 事件驱动 `core/objects.lua`（`NotifyOnNewObject` + `RegisterLoadMapPostHook`；失败退回 `FindAllOf` + 8s 节流）。
- 写入时间预算 `WRITE_BUDGET_MS=6`；`RECONCILE_DELAY=3`。
- 帧率保底 `core/timing.lua` 的 `isStall` 相对基线（`HISTORY_N=9`、`BASE_THRESHOLD=0.5`）。
- 雾诊断 `fog.diag()` 仅在标记文件存在时跑（标记改到 mod 内）。
- `pporig` 墓碑剔除 `isDeadName`。
- 面板 `MAX_ATTEMPTS=1` 熔断、心跳 `HEARTBEAT_TTL=120`。

### 3.4 tooltip 规范
- 去掉人称/黑话/「之前测过/值得重测」；格式：**作用 + 单位范围 + 默认或官方值 + 一句用法**；社区经验单独标 `（社区经验：…）`；**中英双语**。

### 3.5 版本兼容兜底
- 启动校验关键类/属性是否存在，缺失 → 降级 + 面板提示「当前游戏版本不匹配」，不静默崩。

### 3.6 安全 / 礼貌
- **绝不擅自开关用户游戏**；安装/修复需关游戏时弹窗让用户自己关。
- 一切改动先备份、可回滚、留日志；只动自己加的文件。

## 4. UE4SS 推荐包
- 固定版本 `v3.0.1 Beta #0 / Git SHA #f885e8d2`；带调好的 `UE4SS-settings.ini`（`[Hooks]` 全套、`EngineVersionOverride 5.7`）、`mods.txt` 模板、`LICENSE/NOTICE`（UE4SS 为 MIT）。
- 提供「用自带 / 用你已有的」选项；安装器先检测代理 DLL 冲突（`dwmapi.dll` / `version.dll` / `dxgi.dll`）。
- 二进制不塞进 git，放 Release 包。

## 5. 打包 / 发布
- Release zip：mod + panel（self-contained）+ manager + UE4SS 推荐包 + presets + README(中英) + LICENSE。
- 渠道：GitHub（源码 + Releases）；国内 B站 / 3DM / NGA 导流。

## 6. 仓库规范
- 结构：`lua/ panel/ manager/ presets/ tools/ docs/ dist/(ignore)`。
- 分支：`main` + `feature/*`；commit 规范 `feat/fix/docs/chore`。
- `.gitignore`：不提交 `dll/exe/pak/ucas/utoc`、构建产物、个人临时。
- LICENSE：本仓代码 MIT；第三方（UE4SS）随包附其 LICENSE。
- **新仓全新历史**（`git init`），不带旧仓库个人 commit，避免暴露私人邮箱/路径。

## 7. 风险与对策
- 杀软误报（未签名 exe + 注入）→ README 说明 + 校验值；有能力再签名。
- 游戏更新弄坏 mod → 版本检测降级 + 一键更新 + 维护预期。
- 反作弊/联网 → 确认单机无风险（待核）。
- 维护成本 → 版本自适应、CHANGELOG、issue 模板。

## 8. 里程碑
- **M0** 仓库骨架 + 本计划（进行中）
- **M1** 参数表整理（删/藏/重排）+ 去硬编码 + 面板内嵌 + self-contained
- **M2** tooltip 中英改写（先出「旧→新对照表」评审）
- **M3** UE4SS 推荐包 + 许可证
- **M4** PBZModManager MVP（安装/卸载/基础检测）→ 再扩修复/更新
- **M5** 默认中性配置 + 3~5 预设 + README/截图
- **M6** 打包 + GitHub 首发

## 9. 测试策略（避免 bug）
- 离线：`tools/syntaxtest.js`（语法）+ `lint_modules.js` + `run_sim.js`（真 Lua 5.4 行为断言，现有 33 条；**新增**参数裁剪 / 分组 / `ignoreMaster` 用例）。
- 实机：每次改动经 Steam 启动验证——`UE4SS.log` 无 traceback、参数下发正常、雾钩子装上、换图不崩、帧率保底不误冻。
- 回归清单：待写 `docs/TESTING.md`。

## 10. 待确认
- 仓库/项目英文名（暂定 `PBZVisualTweaker`）
- 预设数量与主题
- 长期维护周期
- 是否签名 exe
