# 本地生图工作台（个人分享版）

简体中文 | [English](README.en.md)

维护者：ashishi05 · 个人非官方项目

Windows 桌面文生图 / 图生图工具，生成交给本机 ComfyUI，图片只存本地。**不含模型权重。**

## 功能

- 文生图、图生图（改原图 / 借特征）、批量生成、任务队列
- 4 个模型：Qwen-Image 2.1（标准 / Turbo）、SD 3.5 Medium、Z-Image
- 组合预设、提示词库、角色库、模型配置都是普通 JSON，改文件就能扩展
- 可选本机 AI 助手接口

## 快速开始

1. 装 ComfyUI 便携版（NVIDIA，≥ 0.42.0）
2. 右键 `一键安装.ps1` → 使用 PowerShell 运行
3. 按《模型清单.md》放权重（只放 Qwen Turbo 三个文件也能先跑）
4. 双击桌面「本地生图工作台」

完整步骤和界面说明见 **[使用说明.md](使用说明.md)**。

## 自己扩展

- 加分类 / 标签：编辑 `QwenImageApp\预设库.json`
- 加提示词：编辑 `QwenImageApp\素材库_提示词.json`
- 加角色：编辑 `QwenImageApp\素材库_角色.json`
- 加模型：权重放进 `ComfyUI\models\`，复制模板改权重名，在 `models.json` 加一条

不改程序，保存后重启工作台即可。细节见说明书「自己加东西」。

## 许可与第三方

- 作者编写的代码与文档：**个人使用许可（非商业）**，见 [LICENSE](LICENSE)。允许安装、使用、修改、转发给朋友。
- 第三方组件（ComfyUI、Python 包、模型权重、自定义节点）：按各自许可，见 [文档/第三方来源与授权.md](文档/第三方来源与授权.md)。
- 个人 / 社区项目，**与 DeepSeek、ComfyUI、Qwen、Stability AI 无隶属关系**。
- 免费分享不等于许可；请勿用于违法用途。