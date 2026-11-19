-- 路由表：参数 key -> 引擎描述。
--
-- 这张表是「加参数只加一行」的落点。以前每个参数类型都有一套独立实现
-- （applyFog / applySky / applyFov / applyLightIndirect / applyGUS …），
-- 每套各自实现一遍「开关判断 / 对象验活 / 节流 / 基准 / 读写校验」，
-- 结果每加一个参数就多一份可能漏写的逻辑。
--
-- 字段含义：
--   cls      目标类名（FindAllOf / FindFirstOf 用）
--   scope    "all"（默认，作用于全部）/ "first"（只取第一个）/ "primary"（锁定主对象）
--   prop     属性名
--   setter   对应的 setter 方法名（会 MarkRenderStateDirty，画面才会变）
--   mode     "abs" 绝对值 / "ratio" 相对实时基准的比例 / "mirror" 跟随源对象
--   ttl      对象缓存有效期（tick 数，200ms/tick）
--   eps      判定「已经到了目标值」的容差
--   throttle 同一参数两次写入之间的最小 tick 间隔
--   clamp    目标值上限
--   boot     基准为 0 时用来自愈的初始值
--   onDisable "revert" 表示开关关闭时要主动还原，否则只是不干预
--   persist  是否把 base/written 落盘（热重载后接上，避免累乘）
--
-- ★ 单一写入者原则：
--   每个属性在整份代码里只能有一个写入路径。这张表就是声明处。
--   钩子（features/hooks）只允许读，不允许写。历史上雾有三套写入路径互相打架，
--   engineStep 里那句 `if cloneMode then return end` 就是那个伤疤。

return {
    -- 雾参数。全部走比例模式：1.0 = 原样，0.5 = 一半。
    --
    -- hookManaged = true 表示「这个属性由每帧钩子独占写入」。
    -- 为什么雾密度要这样：某些区域游戏每帧改写它，200ms 轮询永远抢不过。
    -- 钩子装上后 engine 就完全让位，保证单一写入者；钩子没装上时 engine 兜底。
    ["fog.density"]    = { cls = "ExponentialHeightFogComponent", prop = "FogDensity",
                           setter = "SetFogDensity", mode = "ratio", boot = 0.03,
                           hookManaged = true },
    ["fog.extinction"] = { cls = "ExponentialHeightFogComponent", prop = "VolumetricFogExtinctionScale",
                           setter = "SetVolumetricFogExtinctionScale", mode = "ratio", onDisable = "revert" },
    ["fog.maxopacity"] = { cls = "ExponentialHeightFogComponent", prop = "FogMaxOpacity",
                           setter = "SetFogMaxOpacity", mode = "ratio", clamp = 1.0, onDisable = "revert" },
    ["fog.start"]      = { cls = "ExponentialHeightFogComponent", prop = "StartDistance",
                           setter = "SetStartDistance", mode = "abs", onDisable = "revert" },
    ["fog.heightfall"] = { cls = "ExponentialHeightFogComponent", prop = "FogHeightFalloff",
                           setter = "SetFogHeightFalloff", mode = "abs", onDisable = "revert" },
    ["fog.scatter"]    = { cls = "ExponentialHeightFogComponent", prop = "VolumetricFogScatteringDistribution",
                           setter = "SetVolumetricFogScatteringDistribution", mode = "abs", onDisable = "revert" },
    ["fog.voldist"]    = { cls = "ExponentialHeightFogComponent", prop = "VolumetricFogDistance",
                           setter = "SetVolumetricFogDistance", mode = "abs", onDisable = "revert" },
    -- 体积雾的「起始距离 / 近场淡入」：经典雾的 StartDistance 管不到体积雾，
    -- 这两个才是体积雾版的起始距离。把 volstart 推到 20~30 米，房间里的近场浓雾就退掉、远处保留。
    ["fog.vstart"]     = { cls = "ExponentialHeightFogComponent", prop = "VolumetricFogStartDistance",
                           setter = "SetVolumetricFogStartDistance", mode = "abs", onDisable = "revert" },
    ["fog.vnearfade"]  = { cls = "ExponentialHeightFogComponent", prop = "VolumetricFogNearFadeInDistance",
                           setter = "SetVolumetricFogNearFadeInDistance", mode = "abs", onDisable = "revert" },

    -- 平行光强度：比例模式（1.0 = 100%，和雾的浓度比例同一套语义）。
    -- scope="primary" 只动主太阳，不会把月亮/补光一起改成同一个值。
    -- onDisable="revert"：关掉开关回到 100%。
    -- ttl 给 20（4 秒）而不是默认 40，换关卡后能更快重新锁定主光。
    ["sun.intensity"]  = { cls = "DirectionalLightComponent", scope = "primary", ttl = 20,
                           prop = "Intensity", setter = "SetIntensity",
                           mode = "ratio", onDisable = "revert", persist = true },
}
