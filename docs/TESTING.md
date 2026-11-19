# 测试与回归清单（TESTING）

> 改完代码先跑离线测试，再视情况做实机验证。实机验证须经 Steam 客户端启动（直接跑 exe 会被 DRM 静默退出）。

## 1. 离线（每次改动必跑）
```powershell
powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1
```
包含三步：
1. `syntaxtest.js` —— 20 个 Lua 文件语法（真 Lua 5.4 `loadfile`）
2. `lint_modules.js` —— require 是否有效、跨模块调用是否定义、未定义全局
3. `run_sim.js` —— 用模拟 UE 环境跑行为断言（当前 33 条）

### 行为断言覆盖（`tools/sim_test.lua`）
- 主入口可加载、主循环注册、参数表加载
- 雾密度按比例写入、后处理字段下发、原值不每轮刷盘
- 换代延迟下发、墓碑体积记录不落盘
- 三模式：比例/绝对/偏移（含负原值、零原值、origin=1）
- 无原点参数强制绝对
- 计时源走引擎墙钟、卡顿冻结、持续掉帧不误冻
- 换世界重置时间基准、面板拉起不无限重试、json 往返、store 到点落盘

**新增逻辑必加对应断言。** 改参数表后确认项数/分组/`advanced`/`ignoreMaster` 符合预期（`tools/release_prep.js` 会打印）。

## 2. 实机（改动涉及 UE 交互时）
经 `Start-Process 'C:\Program Files (x86)\Steam\steam.exe' -ArgumentList '-applaunch','4115450'` 启动，看 `...\ue4ss\UE4SS.log`：

| 检查点 | 期望 |
|---|---|
| 加载 | `Starting Lua mod 'Velm'` → `[PBZ] Velm 已加载（模块化版本）` |
| 参数表 | `参数表: N 项（雾 M）master=...`，N 与 json 一致 |
| 雾钩子 | `雾钩子已安装（SetFogDensity=true ...）`、`钩子=true` |
| pp 下发 | `pp 写 <字段> = ...`，命中若干体积 |
| 换图 | `换世界: LoadMap 事件` → `后处理体积换代，全部字段重新下发` |
| 报错 | 无 `traceback` / `attempt to index` / `参数出错` |
| 卡顿 | 状态行 `卡顿=N次/最大Xs` 不应持续飙升；BOSS 战不应整场冻结 |
| 面板 | F8 可呼出；托盘有图标；拖动立即生效 |

## 3. 性能不变量（别回归）
- 事件驱动 `core/objects.lua`（`NotifyOnNewObject` + `RegisterLoadMapPostHook`；失败退回 `FindAllOf` + 8s 节流）
- 写入时间预算 `WRITE_BUDGET_MS=6`、`RECONCILE_DELAY=3`
- 帧率保底 `core/timing.lua` 的 `isStall` 相对基线（`HISTORY_N=9`、`BASE_THRESHOLD=0.5`）
- 雾诊断 `fog.diag()` 仅在标记文件存在时跑
- `pporig` 墓碑剔除 `isDeadName`
- 面板 `MAX_ATTEMPTS=1` 熔断、心跳 `HEARTBEAT_TTL=120`

## 4. 发布前
- `package_release.ps1` 生成 `_release\Velm`，结构：`Scripts/ PBZTweaker/ pbz_tweaker.json VERSION`
- 在干净的游戏环境（只装本包）走一遍安装 → F8 → 调参 → 换图 → 退出
- 校验 `_release` 里无用户个人配置（`pbz_tweaker.json` 应是模板 67 项，`pbz_presets.json` 应为对外预设）
