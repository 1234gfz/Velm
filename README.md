# PBZVisualTweaker

> 《影之刃零》(Phantom Blade Zero) 画面调参模组：治好近景「黑乎乎、雾蒙蒙」，可细调雾 / 后处理 / 光照，带面板与预设。

🚧 **开发整理中**（正在从个人自用版整理为可公开发布的版本，暂勿直接使用）。

## 组成（三件套）
- **PBZFog** — UE4SS Lua 模组（核心）
- **PBZTweaker** — WPF 调参面板（F8 / 系统托盘）
- **PBZModManager** — 安装 / 检测修复 / 卸载 管理器（独立 exe）

## 依赖
- 《影之刃零》（Steam）
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)（将随包提供推荐版本，MIT 许可）
- .NET 运行时（面板与管理器为 self-contained 打包，通常无需另装）

## 文档
- 发布计划与工程约束：[docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)

## 许可证
本仓库代码采用 MIT，见 [LICENSE](LICENSE)。随包第三方组件（如 UE4SS）各自遵循其许可。

## 免责声明
本项目仅通过脚本/反射修改**单机**游戏的画面参数，不含任何游戏资源、不涉及破解。使用风险自负；游戏更新可能导致失效，请关注 Releases。
