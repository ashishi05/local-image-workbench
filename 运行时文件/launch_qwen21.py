"""启动工作台使用的 ComfyUI 引擎（仅监听 127.0.0.1:8189）。

在 ComfyUI 便携版根目录运行，例如：

    python_embeded\\python.exe -s launch_qwen21.py

目录约定（二选一）：
  <根目录>\\ComfyUI_Qwen21\\main.py   —— 专用引擎副本（原作者部署方式）
  <根目录>\\ComfyUI\\main.py          —— ComfyUI 便携版自带目录

本文件与 python_embeded、ComfyUI 应位于同一层；工作台（qwen_worker.py）会
自动调用它，通常不需要手动运行。
"""

from pathlib import Path
import os
import runpy
import sys

ROOT = Path(__file__).resolve().parent
CANDIDATES = [ROOT / "ComfyUI_Qwen21", ROOT / "ComfyUI"]
source = next((path for path in CANDIDATES if (path / "main.py").is_file()), None)
if source is None:
    raise SystemExit(
        "找不到 ComfyUI 目录。请把本文件放在 python_embeded 与 ComfyUI 同级的根目录，"
        "并确认 ComfyUI\\main.py 存在。"
    )

# 兼容专用副本里的 runtime_packages（普通便携版没有这个目录，加到 sys.path 无副作用）
sys.path[:0] = [str(source), str(source / "runtime_packages")]
os.chdir(source)
sys.argv = [
    str(source / "main.py"),
    "--listen", "127.0.0.1",
    "--port", "8189",
    "--reserve-vram", "1.5",
    "--offline",
] + sys.argv[1:]
runpy.run_path(str(source / "main.py"), run_name="__main__")
