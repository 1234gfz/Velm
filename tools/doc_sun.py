# -*- coding: utf-8 -*-
"""把平行光接入的实测结论追加到 DESIGN.md。

只写能现场验证的事实和命令，不写"我认为/应该是"。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "DESIGN.md")

SECTION = """
## 22. 平行光强度接入（23:00 完成并实测）

### 22.1 为什么这条能成

`SetIntensity` 是 `UFUNCTION(BlueprintCallable)`（`cpp/sdk/UHTHeaderDump/Engine/Public/LightComponent.h:262`），
和 `SetFogDensity` 同一类——**Lua 能直接调**，不需要写内存、不需要绕反射表、
不需要 AOB 扫描。这是和「运行时创建物体」完全不同的处境。

验证命令：
```bash
grep -n -B1 "void SetIntensity" cpp/sdk/UHTHeaderDump/Engine/Public/LightComponent.h
# 输出应包含 UFUNCTION(BlueprintCallable)
```

### 22.2 关键坑：FindAllOf("DirectionalLight") 返回 0

场景里**有**方向光，但那个调用返回 0。原因：游戏的太阳光挂在蓝图子类上
（actor 类名是 `Ultra_Dynamic_Sky_Child_C`，来自 Ultra Dynamic Sky 插件），
`FindAllOf` 只匹配精确类名。

**正确做法：直接找组件类。** 组件类是引擎原生的，蓝图改不了它的名字。

```lua
FindAllOf("DirectionalLightComponent")   -- 实测返回 3 个
FindAllOf("SkyLightComponent")           -- 2 个
FindAllOf("SkyAtomsphereComponent")      -- 1 个
```

三个方向光组件的原始强度（本场景）：

| 索引 | Intensity | 说明 |
|---|---|---|
| 1 | 0.0 | 未启用（可能是月亮位） |
| 2 | 3.0 | 主太阳 |
| 3 | 0.0 | 未启用 |

### 22.3 关键坑：scope="first" 会取到强度 0 的那个

`engineResolve` 原本只支持 `scope="first"`（`FindFirstOf`）和 `"all"`。
用 `"first"` 拿到的是索引 1（强度 0），改它**画面毫无变化**——实测浪费了两轮。

新增 `scope="primary"`：
- 取**当前强度最大**的那个组件；
- 选定后**锁定**（存 `Engine.primary[cls]`），只有组件失效才重选。
  不锁定的话，用户把强度调低后"最大值"可能变成另一个组件，目标会来回跳。

**锁定比较必须用 `GetFullName()`，不能用 `==`。**
UE4SS 的 `FindAllOf` 每次返回**新的包装对象**，即使指向同一个 UObject，
Lua 层用 `==` 永远不相等。踩这个坑的表现是：每 4 秒（ttl）就"重新锁定"一次，日志刷屏。

验证：
```bash
grep -a "主光锁定" <UE4SS.log> | tail -5 | cut -c1-100
# 正常情况下只应在换关卡/首次加载时出现，不应每隔几秒重复
```

### 22.4 关键坑：基准必须落盘，否则热重载会累乘

`engineStep` 的 ratio 模式把基准存在 `Engine.base`（内存）。Lua 热重载后清空，
重载后读到的当前值**正是我们自己写过的**（比如 6.0），被当成原始值再乘一次：

```
3.0 → (×2) 6.0 → 重载 → 读回 6.0 当基准 → (×2) 12.0 → (×2) 24.0
```

实测确实累乘到了 24.0。

修法：ROUTES 里给参数标 `persist = true`，`base` / `written` 落盘到
`E:/PBZ_engine_state.txt`，格式 `key|base|written`。

```
sun.intensity|3.000000|6.000000
```

验证：改完值后触发一次重载（改 main.lua 内容再 push），光强应保持不变。

### 22.5 关闭开关自动还原

`engineStep` 原本在 `p.enabled == false` 时直接 `return`，等于关掉开关仍保持最后的值。
现在支持 `onDisable = "revert"`：ratio 模式回到 1.0（原始值），abs 模式回到 default。

实测：关掉开关后 `Intensity` 从 6.0 回到 3.0，落盘文件同步变成 `3.000000|3.000000`。

### 22.6 参数定义（panel）

| 字段 | 值 |
|---|---|
| key | `sun.intensity` |
| label | 平行光强度 |
| handler | `light`（走 ROUTES） |
| 语义 | ratio，1.0 = 100%（和雾的浓度比例同一套） |
| min/max/step | 0 / 3 / 0.05 |
| 分组 | 光照与色调 → `sub = "阳光"`（插在「天光」之后） |

ROUTES 定义：
```lua
["sun.intensity"] = { cls = "DirectionalLightComponent", scope = "primary", ttl = 20,
                      prop = "Intensity", setter = "SetIntensity",
                      mode = "ratio", onDisable = "revert", persist = true },
```

### 22.7 适应不同关卡的保障（逐条对应代码）

| 场景 | 处理方式 |
|---|---|
| 换关卡、组件重建 | `engineResolve` 缓存里检查 `volLive`，失效就重新 `FindAllOf` |
| 主光换了（昼夜切换） | ttl=20（4 秒）到期重新 resolve，锁定对象不在集合里就重选 |
| 新关卡太阳强度和旧关卡不同 | ratio 模式检测 `cur != written` 就重认基准 |
| 关卡内没有方向光（室内） | `#objs == 0` 直接 return，不写任何值 |
| 热重载 | base/written 从文件恢复 |
| 游戏重启 | 落盘文件里的 written 与当前值对不上时自动重认基准 |

### 22.8 顺带修的一个 bug：面板拉起冷却单位错误

`ensureTweaker` 的冷却写成 `launchCooldown = 300`，注释说「200ms × 300 = 60 秒」。
但 `ensureTweaker` 是每 60 tick（12 秒）才被调用一次，**300 次 × 12 秒 = 1 小时**。
表现：面板被关掉后一小时都不会被重新拉起。

已改成 `launchCooldown = 5`（5 × 12 秒 = 60 秒）。

验证：
```bash
grep -n "launchCooldown = 5" lua/PBZFog/Scripts/main.lua
```

### 22.9 调试工具：文件触发（不动参数表）

存在 `E:/PBZ_light_probe.txt` 就执行一次，执行后自动删除。内容即命令：

```bash
> E:/PBZ_light_probe.txt                  # 空：只列出 3 个方向光当前值和原始值
echo "2" > E:/PBZ_light_probe.txt         # 把索引 2 提到原始值的 2 倍
echo "restore" > E:/PBZ_light_probe.txt   # 全部还原，并清空引擎基准
```

原始值记录在 `E:/PBZ_light_orig.txt`（`1=0.0 / 2=3.0 / 3=0.0`）。

注意：`restore` 会同时清掉 `Engine.base` / `Engine.written` 和落盘文件，
否则 `engineStep` 下一轮会按旧基准把值写回去（实测过：还原成 3.0 后立刻被写回 6.0）。

### 22.10 未验证的部分

- 换关卡后重新锁定主光：逻辑上已处理，但未实测换关卡
- 昼夜切换时主光从太阳切到月亮：未实测
- 只调平行光能否完全压暗画面：**不能**。实测提亮有效，但场景亮度还有一部分来自
  SkyLight（面板里已有「天光强度」，handler=sky，是绝对值不是比例）
"""


def main():
    with io.open(DOC, "r", encoding="utf-8") as f:
        s = f.read()
    if "## 22. 平行光强度接入" in s:
        print("已存在该章节，跳过")
        return 0
    s = s.rstrip("\n") + "\n" + SECTION
    tmp = DOC + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)
    os.replace(tmp, DOC)
    print("已写入，DESIGN.md 现 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
