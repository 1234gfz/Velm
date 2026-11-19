# 预设（Presets）

## 是什么
面板顶部可以把当前所有参数值存成一套「预设」，之后一键切换。预设文件是 `pbz_presets.json`，与 `pbz_tweaker.json` 放在同一目录（即 `Velm/`）。

## 格式
```json
{
  "预设名A": { "fog.density": 0.8, "img.bloom": 2.0, "img.vignette": 0.3 },
  "预设名B": { "fog.density": 1.0, "img.bloom": 0.675 }
}
```
- 每个预设是「参数 key → 值」的映射；只存 `value`（不存模式/开关）。
- 布尔参数用 `true/false`，其余用数字。
- 加载预设 = 把这些 key 的当前值覆盖掉，再点「应用」生效。预设里没写的 key 保持不动。

## 内置
- `默认（游戏原版）`：所有参数回到游戏默认值，用于一键回退/对比。

（更多主题预设等你定风格后加入；可用 `tools/preset_defaults.js` 重新生成基线。）

## 制作 / 校验
- 生成基线：`node tools/preset_defaults.js "默认（游戏原版）"`
- 校验：`node tools/presets_check.js`（检查每个键存在、类型正确）
- 手写：在面板里调好 → 右侧输入名字 → 「保存预设」即可（面板自动写入 `pbz_presets.json`）。
