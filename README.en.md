# Local Image Workbench (Personal Share Edition)

[简体中文](README.md) | English

A Windows desktop text-to-image / image-to-image tool. Generation is delegated to a local ComfyUI instance; images stay on your machine. **Model weights are not included.**

## Features

- Text-to-image, image-to-image (structure / feature reference), batch generation, task queue
- 4 model profiles: Qwen-Image 2.1 (standard / Turbo), SD 3.5 Medium, Z-Image
- Presets, prompt library, character library and model configs are plain JSON — extend them by editing files
- Optional local agent HTTP API

## Quick start

1. Install ComfyUI Portable (NVIDIA, ≥ 0.42.0)
2. Right-click `一键安装.ps1` → **Run with PowerShell**
3. Put the weights as described in `模型清单.md` (the three Qwen Turbo files are enough for a first run)
4. Launch “本地生图工作台” from the desktop shortcut

Full steps and UI guide: `使用说明.md` (Chinese).

## Extending

- Categories / tags: edit `QwenImageApp\预设库.json`
- Prompts: edit `QwenImageApp\素材库_提示词.json`
- Characters: edit `QwenImageApp\素材库_角色.json`
- Models: put weights under `ComfyUI\models\`, copy a template, add an entry to `models.json`

No code changes needed — save and restart.

## License and third parties

- Code and docs by the authors: **Personal Use License (non-commercial)**, see [LICENSE](LICENSE). Install, use, modify and pass copies to friends.
- Third-party components (ComfyUI, Python packages, model weights, custom nodes): under their own licenses, see [文档/第三方来源与授权.md](文档/第三方来源与授权.md).
- Personal / community project. **Not affiliated with DeepSeek, ComfyUI, Qwen, Stability AI, or any model publisher.**
- Free sharing is not a license. Do not use this package for unlawful purposes.
