# Local Image Workbench (Personal Share Edition)

A Windows desktop text-to-image / image-to-image tool. The UI is a WinForms window; generation is delegated to a local ComfyUI instance. Images stay on your machine — nothing is uploaded to any server.

**Model weights are not included.** Prepare them according to `模型清单.md` (Chinese).

## Features

- Text-to-image, image-to-image (structure / feature reference), batch generation, task queue
- 4 model profiles: Qwen-Image 2.1 (standard / Turbo), SD 3.5 Medium, Z-Image
- Built-in preset groups (style / character / expression / race / body / clothes / composition), prompt library, character library — all extensible
- Local agent HTTP API at `127.0.0.1:19876`, callable by AI assistants

## Quick start

1. Install ComfyUI Portable (NVIDIA build, version ≥ 0.42.0)
2. Right-click `一键安装.ps1` → **Run with PowerShell**
3. Put the weights into the folders listed in `模型清单.md` (only the three Qwen Turbo files are enough for a first run)
4. Launch “本地生图工作台” from the desktop shortcut

Full steps, UI guide and troubleshooting are in `使用说明.md` (Chinese).

## Not included

- Model weights (obtain them under their own licenses)
- Adult content, character preset library, external prompt collections
- ComfyUI source code (this tool calls a locally installed ComfyUI over HTTP)

## License and third parties

- Code and documentation written by the authors: **Personal Use License (non-commercial)**, see [LICENSE](LICENSE). Installation, use, modification and passing copies to friends are allowed; commercial use is not.
- Third-party components (ComfyUI, Python packages, model weights, custom nodes): under their own licenses, see [文档/第三方来源与授权.md](文档/第三方来源与授权.md).
- This is a personal / community project. It is **not affiliated with or endorsed by DeepSeek, ComfyUI, Qwen, Stability AI, or any model publisher.**
- Free sharing is not a license. Do not use this package for unlawful purposes or to harm others' rights.

## For AI agents

Local API, task fields, state machine and acceptance checklist: [文档/给AI的交接文档.md](文档/给AI的交接文档.md) (Chinese).

## Layout

```
一键安装.ps1        Installer: copies the app into ComfyUI Portable and creates a shortcut
工作台文件\         Application (UI, worker, agent API, workflow templates)
运行时文件\         Engine launcher and optional model-path config example
文档\               Manuals, AI hand-off, third-party notices, license
模型清单.md         Weight files, sizes, SHA256, migration commands
```

## Requirements

- Windows 10/11 64-bit
- NVIDIA GPU (12 GB VRAM recommended; 8 GB works at reduced resolution)
- About 49 GB of disk space with all four model sets (app ≈ 8 GB, weights ≈ 39 GB)
- ComfyUI Portable with Qwen-Image 2.1 support (≥ 0.42.0)

---

简体中文 | [English](README.en.md)
