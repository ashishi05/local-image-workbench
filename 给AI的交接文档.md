# 本地生图工作台 · AI 助手交接文档

- 版本：分享包 V1.0（2026-10-26）
- 适用对象：拿到这台电脑、需要调用生图能力的 AI 助手（Codex / DeepSeek / Claude 等，具备本机命令执行或 HTTP 工具）
- 配套文档：`使用说明.md`（给人看）、`模型清单.md`（权重与校验）、`工作台文件\AGENT_API.md`（原始接口速查）

这份文档假设你**没有看过源码**。读完后你应当能：判断环境是否可用、用最稳的方式提交任务、正确等待和取图、出错时定位到具体层、并且在共享队列里不打扰人。

---

## 0. 30 秒速览

工作台是三层结构，**人操作 GUI，AI 走本机 HTTP 接口，两者共用一个队列**：

```
GUI (PowerShell WinForms)  ──写 request.json──▶  qwen_worker.py（每个任务一个进程）
      ▲                                              │  HTTP
      │ 文件桥（inbox/jobs）                          ▼
agent_api.py (127.0.0.1:19876)  ◀──HTTP──  AI 助手     ComfyUI (127.0.0.1:8189)
```

三个入口，按稳定性排序：

1. **`agent_client.py`（推荐）**：Python 客户端，自动读令牌、自动等服务、JSON 输出
2. **HTTP 直连**：`http://127.0.0.1:19876`，`Authorization: Bearer <token>`
3. **GUI**：只给人用；**不要**用鼠标脚本或 UI 自动化驱动它

先记住两个端口和三个路径：

| 名字 | 含义 | 本机示例 |
|---|---|---|
| `<COMFY_ROOT>` | ComfyUI 便携版根目录 | `D:\ComfyUI_windows_portable\ComfyUI_windows_portable` |
| `<APP>` | 工作台程序目录 = `<COMFY_ROOT>\QwenImageApp` | 同上 + `\QwenImageApp` |
| `<PY>` | ComfyUI 自带 Python | `<COMFY_ROOT>\python_embeded\python.exe` |
| 8189 | ComfyUI 引擎端口 | `http://127.0.0.1:8189` |
| 19876 | Agent API 端口 | `http://127.0.0.1:19876` |
| 11434 | Ollama（可选，仅关键词助手） | `http://127.0.0.1:11434` |

---

## 1. 系统地图

### 1.1 进程与数据流

1. 人双击快捷方式 → `powershell.exe -File <APP>\本地生图工作台.ps1`（隐藏控制台，WinForms 窗口）。
2. GUI 启动时：读 `models.json`、读 `settings.json`（没有则用默认值）、初始化 Agent 桥（拿 `agent_api\bridge.lock` 单实例锁）、后台拉起 `agent_client.py serve`（只起 API 服务）。
3. 人点「开始生成」→ GUI 生成 `<APP>\jobs\<任务ID>\request.json`，`Start-Process` 一个 `<PY> -s -u qwen_worker.py request.json` 子进程。
4. `qwen_worker.py`：校验请求 → 检查 8189 是否活着 → 不在就用 `<PY> -s launch_qwen21.py` 拉起 ComfyUI（`cwd=<COMFY_ROOT>`，日志追加到 `<APP>\engine.log`，最多等 120 秒）→ 逐张 POST `/prompt` → WebSocket 听进度 → 从 `/history` 取结果 → `/view` 下载 PNG → 存到你指定的输出目录 → 写 `status.json` / `results.json`。
5. 任务进行中，GUI 每 250ms 读一次 `status.json` 刷新界面；同时把队列状态写进 Agent 桥（`agent_api\jobs\<job_id>\bridge.json`）。
6. AI 提交时走反方向：`agent_api.py` 写 `<APP>\agent_api\inbox\<job_id>.json` → GUI 的定时器（250ms）取走、入队、发布 `bridge.json` → 队列执行时复用同一条 worker 流程。

**一次只跑一个任务**（`$script:worker` 非空时拒绝新任务），其余排队。

### 1.2 组件职责

| 文件（在 `<APP>` 下） | 职责 | 你什么时候会碰它 |
|---|---|---|
| `本地生图工作台.ps1` | 全部 GUI、队列、设置持久化、Agent 桥、预设库 | 只在排障/改界面时；不要用 UI 自动化 |
| `qwen_worker.py` | 单任务执行器：校验、建图、调 ComfyUI、存图、写状态 | 排查"提交成功但生成失败" |
| `launch_qwen21.py` | 在 `<COMFY_ROOT>` 下启动 ComfyUI（`--listen 127.0.0.1 --port 8189 --reserve-vram 1.5 --offline`） | 引擎起不来时手动跑一次看报错 |
| `models.json` | 4 个模型的登记表（ID、模板、权重名、默认步数、CFG） | 换模型 / 加模型 |
| `*_template.json` | ComfyUI API 格式工作流模板（Qwen / SD3.5 / SDXL / Z-Image） | 改工作流 |
| `agent_api.py` | 本机 HTTP 服务：路由、鉴权、幂等、任务记录、图片登记（SQLite） | 接口异常、看错误码 |
| `agent_client.py` | 命令行 + Python 客户端 | **主要调用入口** |
| `agent_bridge.ps1` | GUI 侧的桥：导出 catalog、收 inbox、发布队列状态、执行取消 | 队列状态不同步时 |
| `AGENT_API.md` | 原始接口说明（与本文互补，字段表更简） | 速查 |
| `agent_api\` | `service.json`（服务地址/端口/PID）、`token.txt`（令牌）、`registry.sqlite3`（任务与图片登记）、`inbox/`、`jobs/`、`uploads/`、`catalog.json` | 读令牌、查历史 |
| `jobs\` | 每个任务的 `request.json` / `status.json` / `results.json` / `stop` / worker 日志 | 看真实执行过程 |
| `engine.log` | ComfyUI 引擎日志（追加写） | 引擎/显存/节点报错 |
| `settings.json` | 人的界面状态（模型、提示词、输出目录、参数） | 只读参考，**不要替人改** |

### 1.3 目录速查

```
<COMFY_ROOT>
├─ python_embeded\python.exe          # <PY>
├─ launch_qwen21.py                   # 引擎启动器
├─ ComfyUI\                           # 或 ComfyUI_Qwen21\（专用副本）
│  └─ models\{diffusion_models,checkpoints,text_encoders,vae}\
└─ QwenImageApp\                      # <APP>
   ├─ 本地生图工作台.ps1  qwen_worker.py  agent_api.py  agent_client.py  agent_bridge.ps1
   ├─ models.json  api_template.json  sd35_template.json  sdxl_template.json  zimage_template.json
   ├─ settings.json  engine.log  jobs\  agent_api\  素材库_*.json
   └─ 文档\
```

---

## 2. 环境是否可用：先跑验收再动手

按顺序执行，任何一步失败就先修它，别急着提交任务。

### 2.1 Python 与依赖

```powershell
$root = '<COMFY_ROOT>'
$py = Join-Path $root 'python_embeded\python.exe'
& $py -V
& $py -c "import aiohttp, requests, PIL; print('deps ok')"
& $py -c "import torch; print(torch.__version__, torch.cuda.is_available())"
```

期望：Python 3.11+（原机 3.13.14）、`deps ok`、`True`。`cuda.is_available()` 为 `False` 时不要提交大图任务——会慢到超时。

### 2.2 ComfyUI 版本与节点

```powershell
& $py -c "print(open(r'<COMFY_ROOT>\ComfyUI\comfyui_version.py').read())"
Select-String -Path '<COMFY_ROOT>\ComfyUI\comfy_extras\nodes_qwen.py' -Pattern 'TextEncodeQwenImage21|QwenImage21Cache'
```

要求：版本 ≥ `0.42.0`，且两个节点名都能搜到。缺任一项，Qwen 模型必定失败（SD3.5 / Z-Image 仍可能可用）。

### 2.3 权重是否齐

用 `模型清单.md` 的表，或跑安装器里的检查：

```powershell
# 快速看文件在不在
Get-ChildItem '<COMFY_ROOT>\ComfyUI\models' -Recurse -Filter 'qwen_image_2.1_int8_convrot.safetensors'
```

至少要有你要用的模型那一组。**只放 Turbo 三个文件也能工作**（约 13.5 GB）。

### 2.4 工作台与 API

```powershell
& $py '<APP>\agent_client.py' health
& $py '<APP>\agent_client.py' models
```

期望：`health` 返回 `workbench_online: true`；`models` 返回 4 个模型。

> 如果 `workbench_online` 是 `false`：GUI 没开。用 `agent_client.py start`（会打开可见窗口）或让用户双击快捷方式。**不要**靠反复提交任务来"唤醒"。

### 2.5 界面自检（可选，会弹窗）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File '<APP>\本地生图工作台.ps1' -SelfTest -AppDirectory '<APP>'
```

这是一套内置的界面/队列/预览回归测试，全部通过会打印一串 `..._OK` 行并以 0 退出。机器第一次装好时值得跑一次。

---

## 3. 启动、停止、重启的确切语义

| 动作 | 结果 |
|---|---|
| 双击桌面「本地生图工作台」 | GUI 起来；API 服务自动跟着起；引擎**不**起来（懒启动） |
| 第一次「开始生成」 | worker 发现 8189 没响应 → 拉起引擎，最多等 120 秒；再失败就写 error |
| 关窗口 | 不杀已提交的后台任务，图片照样落盘；队列（本次会话）丢失 |
| 顶部「重启工作台」 | 保存设置 → 新进程重开 → 旧窗口关闭（有任务时按钮无效） |
| `agent_client.py start` | 服务没起就起服务；GUI 没开就打开 GUI |
| `agent_client.py serve` | 只保证 API 服务在，不开窗口 |
| 杀 `python.exe` | 可能杀掉 worker 或引擎；worker 被杀时任务停在 running 直到状态文件不再更新 |

约束：

- **GUI 单实例**：靠 `agent_api\bridge.lock` 独占锁，第二个 GUI 不会抢队列。
- **API 单实例**：靠 19876 端口。端口被占时 `agent_api.py` 直接退出（"refusing to replace its owner"），不会顶掉别人。
- **引擎单实例**：靠 8189 端口。已经有一个引擎在跑时 worker 直接复用它。
- 工作台离线超过 6 秒（心跳过期），API 对新任务返回 `503 workbench_offline`。

---

## 4. 生成请求的数据模型

这是 worker 真正接受的 `config`（GUI 的 `request.json` 与 API 归一化后的结果同构）。API 会把字段裁剪/校验成这个形状。

### 4.1 字段表

| 字段 | 类型 | 默认 | 约束 | 说明 |
|---|---|---|---|---|
| `mode` | `text` / `edit` | 必填 | — | 文生图 / 图生图 |
| `model` | string | `qwen21` | 必须在 `models.json` 里 | 见 §5 |
| `prompt` | string | `''` | 非空（段落在 `prompts` 时按元素校验） | 主提示词；`edit` 模式下是修改要求 |
| `prompts` | string[] | 无 | 1..10000；`edit` 只能 1 段 | 多段批量：每段各生成 `count` 张 |
| `negative_prompt` | string | `''` | — | 负向词；API 默认空，不会偷偷带上人的设置 |
| `width` / `height` | int | 1024 | 256..2048，且 %32==0 | 文生图尺寸 |
| `resolution` | int | 1024 | 512 / 1024 / 1536 | 图生图清晰度（按面积缩放，保持原图比例） |
| `steps` | int | 模型默认 | 1..100；Turbo 必须 8 | 采样步数 |
| `cfg` | float | text 用模型默认，edit 用 5 | 1..10 | 引导强度 |
| `seed` | int | `-1` | `-1` 或 0..2^63-1 | `-1` 每张随机；固定值批量时逐张 +1 |
| `count` | int | 1 | 1..2^31-1（API），界面建议 ≤100 | 每段/每张参考图的生成数量 |
| `images` / `image` | string[] / string | — | `edit` 必填，文件必须存在且是有效图片 | 参考图本机绝对路径 |
| `reference_count` | int | 1 | ≥1 | `edit`：每张参考图生成几张 |
| `output` | string | 人的设置 | **必须是绝对路径** | 输出目录，不存在会创建 |
| `name` | string | 无 | — | 备用字段（文件名前缀走 `output_characters`） |
| `output_characters` | object[] | `[]` | `{name, text}` | 若 `text` 作为整段出现在提示词里，用它当文件名前缀 |
| `random_presets` | object[] | `[]` | `{key, choices[]}` | 每张重新抽一个，拼到提示词尾部；会避开上一张的选择 |
| `ref_mode` | `structure` / `feature` | `structure` | — | 结构参考（改原图）/ 特征参考（借元素） |
| `ref_preset` | string | 随 mode | structure: `subtle`/`normal`/`redraw`；feature: `free`/`balanced`/`close` | 强度档位 |
| `ref_element` | string | `character` | `character`/`pose`/`style`/`all` | 特征参考借什么 |

### 4.2 批量语义（容易踩坑，务必读）

- **文生图 + `prompts`**：总张数 = `len(prompts) × count`。每段提示词单独跑 `count` 张，文件名带 `组号-序号` 逻辑（`random_presets` 里也用它编号）。
- **文生图 + 单 `prompt`**：总张数 = `count`。
- **图生图**：总张数 = `len(images) × reference_count`；`count` 会被当成 `reference_count`。
- `edit` 只接受**一段**要求，所有参考图共用同一句修改指令。想每张不同要求 → 分多次任务。
- 种子：`-1` 时每张用随机数；固定种子时第 i 张用 `(seed + i) % 2^63`。要复现，种子、模型、尺寸、步数、CFG 必须全部一致。

### 4.3 校验顺序（worker `build_prompt` / `plan_tasks`）

1. `mode` 合法 → `prompt` 非空
2. `width/height/resolution` ∈ [256,2048] 且 32 倍数
3. `steps` ∈ [1,100]；`seed` ∈ [0,2^63)；`cfg` ∈ [1,10]
4. 模型在 `models.json` 里；`fixed_sigmas` 模型强制 8 步
5. 模板存在且是合法 JSON
6. `kind=sd35/sdxl/zimage` 且 `mode=edit` → 直接拒绝（这些模型只支持文生图）
7. `edit`：参考图必须存在、能被 PIL 打开
8. 输出路径必须是绝对路径，且能创建/写入（worker 会先写一个探针文件再删）

失败信息通常是中文短句，直接转述给用户即可，别自己编原因。

### 4.4 输出与命名

- 目录：`output`（绝对路径）
- 文件名：`<角色前缀>_<n>.png` 或 `<n>.png`
- `n`：扫描目录内同前缀图片，取最大编号 +1，**永不覆盖**
- 同时把 `seed`、`sha256`、`effective_prompt` 写进结果，API 再登记成 `image_id`

---

## 5. 模型与工作流

### 5.1 `models.json` 登记表

| id | 名称 | 模板 | 模式 | 默认步数 | 默认 CFG | 关键权重 |
|---|---|---|---|---|---|---|
| `qwen21` | Qwen-Image-2.1 标准版 | `api_template.json` | text, edit | 文 25 / 图 40 | 1.0 | qwen_image_2.1_int8_convrot + qwen3vl_8b_w4a8 + qwen_image_2.1_vae_bf16 |
| `qwen21_turbo` | Qwen-Image-2.1 Turbo | `api_template.json` | text, edit | 8（固定） | 1.0 | qwen_image_2.1_turbo_int8_convrot + 同上 |
| `sd35` | SD 3.5 Medium | `sd35_template.json` | text | 28 | 4.5 | sd3.5_medium + clip_l + t5xxl_fp8 |
| `zimage` | Z-Image | `zimage_template.json` | text | 30 | 4.0 | z_image_int8_convrot + qwen_3_4b_fp4_mixed + ae |

> `agent_api.py` 里"是否支持 edit"写死为 `qwen21` / `qwen21_turbo`。新增可编辑模型时要同步改这一处。

### 5.2 模板与图生图实现

- 模板是 ComfyUI 的 **API 格式**（节点 ID → `class_type` + `inputs`），不是网页导出的 workflow。
- Qwen 文生图：`UNETLoader → CLIPLoader(qwen_image) → TextEncodeQwenImage21 → QwenImage21Cache → KSampler → VAEDecode → SaveImage`。
- Qwen 图生图两种路径：
  - `structure`：把参考图编码进 latent 序列（`images.image_1`），按 `ref_preset` 调 denoise（subtle 0.35 / normal 0.65 / redraw 0.9）；低强度时先 `ImageScaleToTotalPixels` 再 `VAEEncode`。
  - `feature`：`ref_element` 决定借人物/姿态/画风/综合；强度 `ref_strength` 0..100（<20 只做视觉参考，否则 denoise = 0.35 + (100-strength)/100×0.6）。
- Turbo 的 `fixed_sigmas` 会改写图：插入 `RandomNoise + CFGGuider + KSamplerSelect + ManualSigmas`，用 `SamplerCustomAdvanced` 替换 `KSampler`；denoise < 1 时 sigmas 按比例缩放。
- `SaveImage.filename_prefix` 只是 ComfyUI 内部临时名；最终文件由 worker 下载后按 §4.4 重命名。

### 5.3 换/加模型的步骤（别跳步）

1. 权重放进 `models\<对应子目录>`，文件名与模板里的 `unet_name` / `ckpt_name` / `clip_name` / `vae_name` **逐字一致**。
2. 复制一份模板，改节点和权重名。
3. 在 `models.json` 加一条：`id`、`name`、`template`、`kind`（可选）、`diffusion_model`/`checkpoint`、`text_steps`/`edit_steps`、`text_cfg`、`prefix`。
4. 用 8189 的 `/object_info/<节点名>` 确认节点存在；或直接在 GUI 里跑一张最小图。
5. 若新模型要支持 edit，记得同步 `agent_api.py` 的模型白名单。

**不要**把 bf16 权重改成 int8 文件名来"凑"——模板写死名字，量化版结构也不同。

---

## 6. Agent HTTP API

### 6.1 发现与鉴权

- 地址：`<APP>\agent_api\service.json` → `{"url": "http://127.0.0.1:19876", "pid": ..., "token_file": "..."}`
- 令牌：`<APP>\agent_api\token.txt`（43 字符），请求头 `Authorization: Bearer <token>`
- 只监听 `127.0.0.1`；带 `Origin` 头的请求一律 403（防浏览器 CSRF）；`Host` 必须是 `127.0.0.1` / `localhost`
- **禁止**把 token 写进 URL、提示词、命令行参数、日志或提交给任何远端

### 6.2 路由

| 方法 | 路径 | 成功码 | 说明 |
|---|---|---|---|
| GET | `/v1/health` | 200 | `version`、`workbench_online`、`queue_paused`、`session` |
| GET | `/v1/models` | 200 | 模型、模式、默认值、约束 |
| GET | `/v1/presets?query=` | 200 | 预设（来自 `catalog.json`），含稳定 ID |
| GET | `/v1/characters?query=` | 200 | 角色（本分享包默认空） |
| POST | `/v1/images` | 201 | body `{"data_base64": "..."}`，返回 `image_id` |
| POST | `/v1/jobs` | 202 | 提交任务，返回 job 对象 |
| GET | `/v1/jobs/{id}` | 200 | 状态/进度/结果/错误 |
| GET | `/v1/jobs/{id}/wait?timeout=30` | 200 | 最多等 30 秒，状态变化或阻塞就提前返回 |
| POST | `/v1/jobs/{id}/cancel` | 200 | body `{}` |
| GET | `/v1/images/{id}` | 200 | 默认原始字节；`?format=json` 带 base64；`?format=metadata` 只元数据 |

### 6.3 提交（POST /v1/jobs）

允许字段（**出现未知字段直接 400**，拼错不会被忽略）：

```
request_id, source, model, mode, prompt, prompts, negative_prompt,
preset_ids, character_ids, random_categories, image_ids, count,
width, height, steps, seed, cfg, resolution, ref_mode, ref_preset,
ref_element, output
```

要点：

- `request_id` 必填（≤128 字符）。**一次真实意图一个 ID**；网络重试沿用同一个 ID。
- 幂等键 = `request_id` + 整个 body 的 SHA256。同 ID 同内容 → 返回原任务（不会重复生成）；同 ID 不同内容 → `409 request_id_conflict`。
- 工作台离线 → `503 workbench_offline`（`retryable: true`），先起 GUI 再重试。
- 提交成功 ≠ 已开始跑：返回 `state: queued` 是正常的。
- `preset_ids` / `character_ids` 必须是 `/v1/presets`、`/v1/characters` 返回的 ID；`random_categories` 是预设分类名（如 `style`、`expression`），每张重新抽。
- `image_ids` 里的图会解析成本机路径；`mode=text` 带图 → 400。

最小可提交示例：

```json
{
  "request_id": "codex-20261026-001",
  "source": "codex",
  "model": "qwen21_turbo",
  "mode": "text",
  "prompt": "清晨山间的一座木亭，薄雾，自然光",
  "width": 768,
  "height": 768,
  "count": 1,
  "seed": -1
}
```

### 6.4 状态机

```
queued ──▶ running ──▶ done
   │           ├──────▶ error
   ├───────────┴──────▶ cancelled
   └── blocked_reason: queue_paused / workbench_offline / workbench_restarted
```

- `done` / `error` / `cancelled` 是终态。
- `blocked_reason` 非空时任务没在推进，`queued` 且 `queue_paused` 表示人按了暂停——**不要替人恢复队列**。
- `workbench_restarted`：GUI 重启过，会话里的队列已丢失；该任务不会自动重跑，报告给人。
- 状态里的 `total` = `count × 段数`（edit 时 `count × 图数`）；`completed` 取状态文件与已登记图片数的较大值。
- `progress` 是 0..100 的总体百分比；`message` 是给人看的中文进度。

### 6.5 取图

- `GET /v1/images/{id}` 返回真实字节（Content-Type 按图片格式），**适合交给你的图片查看工具**。
- `?format=json` 返回 `{image_id, url, width, height, mime_type, sha256, data_base64, ...}`。
- `?format=metadata` 只返回元数据。
- 图片被删除 / 被同名替换 → `410`（不会返回"另一张图"）。要改图就继续用 `image_id`，不要下载再上传。

### 6.6 错误码

| 码 | 含义 | 处理 |
|---|---|---|
| 400 | 参数错误（`invalid_parameter` / `unknown_parameter` / `empty_prompt` …） | 按 `error.field` 修参数，**别原样重试** |
| 401 | 缺/错令牌 | 重新读 token.txt |
| 403 | 带了 Origin / 非 loopback Host | 用本机客户端 |
| 404 | 未知路由 / job / image | 检查 ID |
| 409 | `request_id` 内容冲突 | 换新 ID |
| 410 | 图片被删/被替换 | 重新生成或重新上传 |
| 413 | body > 32 MiB / 图片 > 24 MiB 或 > 24 MP | 压缩 |
| 415 | 非 `application/json` | 改 Content-Type |
| 503 | 工作台离线 | 起 GUI，稍后重试 |

错误体统一为 `{"error": {"code", "message", "field", "retryable"}}`。生成失败的错误在**任务对象**的 `error` 字段里，HTTP 仍是 200。

### 6.7 限制

- 请求体 ≤ 32 MiB；单图 ≤ 24 MiB 且 ≤ 2400 万像素；`prompts` ≤ 10000；`image_ids` ≤ 256；`preset_ids`/`character_ids` 各 ≤ 256；`random_categories` ≤ 32
- `wait` 的 `timeout` ∈ [0, 30] 秒；长时间任务请循环等待，每次 ≤30 秒
- 服务是多线程 `ThreadingHTTPServer`，但底层队列仍是单任务串行

---

## 7. CLI 与 Python 客户端

### 7.1 命令行

```powershell
$py = '<PY>'
$cli = '<APP>\agent_client.py'
& $py $cli start
& $py $cli serve
& $py $cli health
& $py $cli models
& $py $cli presets --query 光影
& $py $cli characters --query 云堇
& $py $cli upload .\reference.png
& $py $cli submit --model qwen21_turbo --prompt "清晨木亭，自然光" --source codex --request-id codex-001
& $py $cli status job_xxxxxxxx
& $py $cli wait job_xxxxxxxx --timeout 30
& $py $cli image img_xxxxxxxx --base64
& $py $cli image img_xxxxxxxx --out D:\out.png
& $py $cli cancel job_xxxxxxxx
```

注意：

- 所有文本输出都是 JSON；错误走 stderr + 非零退出。
- `submit --json '<json>'` 直接传 JSON；`submit --file request.json`（或 `--file -` 从 stdin）能避开 shell 引号转义，复杂请求优先用它。
- `image --out` 用独占方式写文件（`xb`），目标已存在会失败——这是防覆盖设计，换个名字即可。
- 客户端自己读 `service.json` 和 `token.txt`，**不要把令牌当参数传**。
- `start` 会打开可见窗口；批量自动任务里用 `serve`。

### 7.2 Python

```python
import sys
APP = r'<APP>'
sys.path.insert(0, APP)
from agent_client import Client

client = Client(APP)
client.start()                       # 起服务 + GUI（已在运行则复用）

job = client.call('/v1/jobs', {
    'request_id': 'codex-002',
    'source': 'codex',
    'model': 'qwen21_turbo',
    'mode': 'text',
    'prompt': 'A wooden pavilion at sunrise',
    'width': 768, 'height': 768, 'count': 1, 'seed': -1,
})
jid = job['job_id']

while True:
    st = client.call(f'/v1/jobs/{jid}/wait?timeout=30')
    if st['state'] in ('done', 'error', 'cancelled'):
        break
    if st.get('blocked_reason'):
        raise RuntimeError('blocked: ' + st['blocked_reason'])

img = st['results'][0]['image_id']
png = client.call(f'/v1/images/{img}', raw=True)   # 原始字节
```

改图时直接引用 `image_id`：

```python
edited = client.call('/v1/jobs', {
    'request_id': 'codex-003', 'source': 'codex',
    'model': 'qwen21_turbo', 'mode': 'edit',
    'image_ids': [img],
    'prompt': '把屋顶改成蓝色，保留建筑和视角',
    'resolution': 1024, 'ref_mode': 'structure', 'ref_preset': 'normal',
})
```

---

## 8. 和人共用一个队列的规矩

1. **source 打标**：`source` 写 `codex` / `deepseek` / 你的名字，队列里能区分。
2. **人工暂停优先**：看到 `blocked_reason=queue_paused` 就停下来报告，不要调用取消/恢复，也不要改 GUI。
3. **不要用 UI 自动化**：不模拟鼠标键盘、不点按钮、不改 `settings.json` 里人的提示词和输出目录。
4. **取消要克制**：`cancel` 只该取消你自己的任务；别人的任务 ID 不要碰。
5. **重试规则**：网络失败沿用原 `request_id`；改了意图就换新 ID。
6. **别并发送很多任务**：底层串行，堆太多只会让人的任务排在后面；一次 1～2 个足够。
7. **记录 ID**：提交后把 `job_id`、`image_id` 记进你的工作笔记，后续改图靠它。

---

## 9. 已知坑（按出现频率排序）

| 现象 | 原因 | 处理 |
|---|---|---|
| `Start-Process` 报 "Item has already been added. Key: NO_PROXY" | 环境里同时有 `HTTP_PROXY`/`http_proxy` 这类大小写重复变量（PS 5.1 内部字典区分大小写） | 脚本已自带清理；若仍出现，手动删重复变量后重启 GUI |
| 提交成功但一直 `queued` | 人暂停了队列 / 工作台离线 / GUI 重启 | 看 `blocked_reason`，报告给人 |
| 生成报"参数或模型配置未通过检查" | 权重缺失或文件名不符 | 对照 §5 和 `模型清单.md` 逐字核对 |
| 引擎起不来，`engine.log` 有节点红字 | ComfyUI 版本 <0.42 或节点缺失 | 更新 ComfyUI 便携版 |
| `8189` 已占用 | 之前手动开的引擎/僵尸进程 | 复用即可；要换端口得同时改 `qwen_worker.py` 的 `URL` 和 `launch_qwen21.py` |
| `19876` 已占用 | 残留 `agent_api.py` 进程 | 结束它或重启；服务不会顶替占用者 |
| 输出路径非法 | 传了相对路径 | 必须绝对路径，如 `D:\out` |
| 图片文件名从 1 重新开始 | 输出目录换了 | 编号按目录内现有文件算；换目录就重新计数 |
| 图生图结果"不像原图" | `ref_preset` 太轻 | `structure` 用 `normal`/`redraw`，或 `feature` 的 `close` |
| 中文路径异常 | 个别老工具链对非 ASCII 路径敏感 | 路径尽量用英文；本工作台本身支持中文 |
| 界面提示"素材库缺失" | 分享包未含角色库/提示词库 | 正常，别去补；预设走内置 |
| 关键词助手不可用 | 没装 Ollama / 没有文字模型 | 与生图无关，跳过 |

---

## 10. 排障决策树

```
生成失败
├─ 状态文件有 error？
│  ├─ message 含"引擎" → 看 engine.log，查版本/显存/端口
│  ├─ message 含"参数/模型配置" → 查权重文件名与 models.json
│  └─ message 含"参考图片" → 路径/格式问题
├─ 一直 queued → health.blocked_reason
├─ running 但进度不动 → 看 engine.log 是否在加载模型；显存不足会卡很久
├─ 浏览器能开 8189 但工作台不行 → 端口/代理；本机代理设置（HTTP_PROXY 等）可能影响本地请求
└─ 图片没出现 → 确认 output 目录写权限；查 results.json 是否为空
```

常用定位命令：

```powershell
Get-Content '<APP>\engine.log' -Tail 80
Get-ChildItem '<APP>\jobs' | Sort-Object LastWriteTime -Descending | Select-Object -First 3
Get-Content '<APP>\jobs\<id>\status.json' -Raw
Get-Content '<APP>\jobs\<id>\worker.stderr.log' -Tail 40
& $py '<APP>\agent_client.py' health
```

---

## 11. 验收清单（装好后照做一遍）

| # | 步骤 | 期望 |
|---|---|---|
| 1 | `agent_client.py health` | 200，`workbench_online: true` |
| 2 | `agent_client.py models` | 4 个模型，`qwen21` 支持 edit |
| 3 | 提交 `qwen21_turbo`、512×512、1 张、seed -1 | 返回 `job_id`，state `queued` |
| 4 | 循环 `wait` ≤30s | 最终 `done`，`results` 非空，有 `image_id` |
| 5 | `image <id>` 取字节 | PNG 魔数 `\x89PNG`，尺寸 512×512 |
| 6 | 用该 `image_id` 提交 edit | `done`，结果图存在 |
| 7 | 同 `request_id` 重发第 3 步 | 返回**同一个** `job_id`，不新增任务 |
| 8 | 同 `request_id` 改提示词 | `409 request_id_conflict` |
| 9 | 提交 `mode=edit` 但不给图 | `400 missing_image` |
| 10 | Turbo 传 `steps=12` | `400`（Turbo 固定 8 步） |
| 11 | `cancel` 一个排队任务 | 状态变 `cancelled`，队列其他任务不受影响 |

全部通过，才算交接完成。

---

## 12. 安全与合规

完整使用条款见 `使用说明.md` 第十章「免责声明与使用条款」。作为 AI 助手，你**不得协助规避**其中的禁止用途；遇到违规请求应拒绝并说明原因。

- **未成年人保护**：不得生成、传播涉及未成年人的性化、剥削或其他侵害内容；正常的儿童题材插画（绘本、亲子等）可以创作，但不得性化或侵害。这是硬性红线，不因二次元或虚构而放宽。
- **令牌**：`agent_api\token.txt` 是唯一凭据，等同于本机生图权限。不要打印、不要写进日志/提示词/远端请求。
- **本机限定**：接口只 bind `127.0.0.1`，拒绝带 `Origin` 的请求。不要试图开代理或映射到局域网。
- **真人素材**：使用真人参考图需取得本人明确同意；不得生成未经同意的换脸、拟声、私密合成内容。
- **AI 标识**：对外发布生成内容时，按当地法律（如中国《人工智能生成合成内容标识办法》）与平台规则添加显式/隐式标识，不得协助去除或伪造标识。
- **版权**：生成的角色形象（游戏/动漫）版权归原权利人，商用前确认授权；模型许可差异大，商用前逐项核对。
- **磁盘**：`jobs\`、`agent_api\uploads\` 会随使用增长，定期清理旧任务目录（不影响已生成图片）；清理前注意其中含明文提示词。

---

- **代码许可**：作者编写的代码与文档采用个人使用许可（见 `LICENSE`），允许本机安装、使用、修改与转发给朋友（非商业、附许可与署名）；第三方组件按各自许可，`LICENSE` 不能替第三方补授权；图标已换为自制，来源清单见 `文档/第三方来源与授权.md`。

## 13. 维护与变更

- 分享包版本 `V1.0`；升级时覆盖 `<APP>` 下的代码文件即可，**保留** `settings.json`、`素材库_*.json`、`agent_api\`、`jobs\`。
- 修改 `本地生图工作台.ps1` 后必须保证文件是 **UTF-8 with BOM**——PowerShell 5.1 对无 BOM 的中文脚本会按 ANSI 读，直接语法报错。
- 改 GUI 前先跑 `-SelfTest`，它是这套界面的回归基线。
- 改 API 后跑 `test_agent_api.py`（原机带，分享包未含）或按 §11 手工回归。
- 日志不自动轮转：`engine.log` 和 `jobs\` 会一直长，定期归档。

---

## 14. 扩展指南：模型 / 预设 / 提示词库 / 角色库

用户会让你“加个模型 / 加套预设 / 导个提示词库”。原则：**改数据文件，不改程序**；先备份、再校验、最后让用户重启验证。

### 14.1 边界（先读）

- 本包不包含成人向模型、预设或提示词库。
- 只协助合法、通用创作向的扩展：风景、人物、服装、光影、构图、原创角色。
- 不得协助生成、整理、推荐成人或性化内容、涉及未成年人的性化/剥削/侵害内容、侵权角色库、来源不明的数据集；正常儿童题材插画（绘本、亲子等）可以协助，但不得含性化或侵害表达。遇到违规请求拒绝并说明（见 §12）。
- 示例一律用中性题材，不要主动把用户往成人内容引导。

### 14.2 模型

**权重目录**

| 类型 | 目录 |
|---|---|
| 单文件 checkpoint | `ComfyUI\models\checkpoints` |
| 分离式主模型 | `diffusion_models` |
| 文本编码器 | `text_encoders` |
| VAE | `vae` |

**模板选择**

| 模型类型 | 模板 | 关键字段 |
|---|---|---|
| SDXL checkpoint | `sdxl_template.json` | `ckpt_name` |
| SD3.5 | `sd35_template.json` | `ckpt_name`、两个 text encoder 文件名 |
| Qwen-Image | `api_template.json` | `unet_name`、`clip_name`、`vae_name` |
| Z-Image | `zimage_template.json` | `unet_name`、`clip_name`、`vae_name` |

**`models.json` 字段**

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 唯一短名，接口提交时用 |
| `name` | 是 | 下拉框显示名 |
| `template` | 是 | 模板文件名 |
| `kind` | 否 | `sd35` / `sdxl` / `zimage`；缺省按 Qwen 处理 |
| `checkpoint` | 看模板 | 单文件 checkpoint 文件名 |
| `diffusion_model` | 看模板 | 分离式主模型文件名 |
| `text_steps` / `edit_steps` | 建议 | 默认步数 |
| `text_cfg` | 否 | 文生图默认 CFG |
| `prefix` | 否 | ComfyUI 临时文件名前缀 |
| `fixed_sigmas` | 否 | 固定时间表；填了则步数必须匹配 |

示例：

```json
{
  "id": "mysdxl",
  "name": "我的 SDXL 风景模型",
  "template": "sdxl_template.json",
  "kind": "sdxl",
  "checkpoint": "landscape_v1.safetensors",
  "text_steps": 28,
  "edit_steps": 28,
  "text_cfg": 6.0,
  "prefix": "MySDXL/App",
  "fixed_sigmas": null
}
```

约束：

- `kind` 为 `sd35` / `sdxl` / `zimage` 的模型只支持 `mode=text`。
- `fixed_sigmas` 非空时步数必须等于该时间表长度（Turbo = 8）。
- 要让新模型支持 edit，需同步改 `agent_api.py` 里的模型白名单（目前硬编码 `qwen21` / `qwen21_turbo`）。
- 模板是 ComfyUI **API 格式**，不是网页导出的 workflow。

验证：`/v1/models` 出现新 id → 提交 512×512 测试 → 查 `engine.log`。

### 14.3 预设

`preset_library_changes.json`：

```json
{
  "version": 2,
  "deleted": [],
  "custom": [
    { "Key": "style:custom_a1b2c3d4", "Name": "画风 · 淡彩水粉", "Text": "soft watercolor, pastel palette, light paper texture", "Random": false },
    { "Key": "clothes:custom_e5f6a7b8", "Name": "服装 · 长风衣", "Text": "long trench coat, belted waist, rolled sleeves", "Random": false }
  ],
  "overrides": [
    { "Key": "lighting:1", "Name": "光线镜头 · 窗边自然光", "Text": "soft window light, gentle shadows, warm tone", "Random": false }
  ]
}
```

- `custom` 的 Key 必须匹配 `^[a-z]+:custom_[a-f0-9]+$`
- `overrides` / `deleted` 的 Key 必须是内置项（`分类:序号`）
- 分类：`style` / `character` / `expression` / `race` / `body` / `clothes` / `composition` / `count` / `haircolor` / `hairstyle` / `eyecolor` / `pose` / `scene` / `lighting`
- 优先建议用户走界面「管理预设」，避免手写 Key 出错

### 14.4 提示词库

`素材库_提示词.json`：`{version, updated, source, groups: {分类: [{id, text}]}}`。

```json
{
  "version": 1,
  "updated": "2026-10-26",
  "source": "自建",
  "groups": {
    "光影": [ { "id": "L001", "text": "soft window light, gentle shadows, warm tone" } ],
    "构图": [ { "id": "F001", "text": "wide shot, rule of thirds, deep depth of field" } ]
  }
}
```

### 14.5 角色库与收藏

`素材库_角色.json`：`{version, updated, female: {作品: [{cn, en, desc}]}, male: {...}}`。

```json
{
  "version": 1,
  "updated": "2026-10-26",
  "female": { "原创角色": [ { "cn": "山间旅人", "en": "original character, mountain traveler", "desc": "green cloak, leather boots" } ] },
  "male": {}
}
```

`素材库_收藏.json`：`{favorites: {"英文标签": 星级0-3}}`。

### 14.6 操作流程（7 步）

1. 读现状：读目标 JSON，确认结构。
2. 备份：`Copy-Item x "$x.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"`。
3. 生成 JSON：UTF-8；先写 `.tmp`，校验后 `Move-Item -Force` 替换。
4. 校验：`& $py -c "import json,sys;json.load(open(sys.argv[1],encoding='utf-8-sig'))" <file>`；确认引用的权重文件存在。
5. 不改 `settings.json`、不动用户提示词与输出目录。
6. 让用户重启工作台；再 `agent_client.py models` / `presets --query` 确认。
7. 提交 512×512 一张试跑；失败看 `engine.log`；记录改动与备份路径。

### 14.7 常见错误

| 现象 | 原因 | 处理 |
|---|---|---|
| 新模型不出现 | JSON 语法错 / `id` 重复 | 校验 JSON |
| “模型配置未通过检查” | 文件名与模板不符 | 逐字核对 |
| 节点不存在 | 模板用了未装节点 | 换模板 / 装节点 |
| 图生图不可用 | `kind` 不支持或被白名单挡住 | 用 Qwen 或改白名单 |
| Turbo 步数错误 | `fixed_sigmas` 固定 8 步 | 按 8 步提交 |
| 预设不生效 | 没重开对话框 / Key 非法 | 检查 Key 规则 |

## 附录 A：数据文件 schema（实现细节，不是稳定 API）

**`jobs\<id>\status.json`**（worker 原子写）

```json
{
  "state": "running|done|error|cancelled|stopping",
  "message": "第 1/2 张 · 正在生成：12 / 25 步",
  "progress": 40,
  "item_progress": 80,
  "completed": 0,
  "total": 2,
  "output": "D:\\生图\\42.png",
  "outputs": [{"output": "...", "seed": 42, "sha256": "...", "effective_prompt": "..."}],
  "seed": 42,
  "prompt_id": "comfy-prompt-id",
  "random_presets": {"style": "..."}
}
```

**`jobs\<id>\results.json`**：结果数组，元素含 `output`、`seed`、`sha256`、`effective_prompt`，以及 `model`/`mode`/`prompt`/`negative_prompt`/`steps`/`cfg`/`width`/`height`。

**`settings.json`**：`model`、`prompt`、`fixedPrompt`、`negPrompt`、`output`、`width`、`height`、`steps`、`cfg`、`count`、`seed`、`mode`、`sizePreset`、`images`、`preset*Index`、`randomPresetGroups`、`selectedFixedKeys`、`fixedAppliedTexts`。

**`agent_api\catalog.json`**：`{"output": "D:\\...", "presets": [{"id","name","text","category","random"}], "characters": [{"id","name","text","tag","description","work","gender"}]}`，由 GUI 每 25 个 tick（约 6 秒）重导出。

**`agent_api\jobs\<id>\bridge.json`**：`session`、`state`、`queue_number`、`queue_position`、`source`、`message`、`code`。

## 附录 B：常用 PowerShell 片段

```powershell
# 读令牌（只在本机进程内用，不要打印到共享日志）
$token = Get-Content '<APP>\agent_api\token.txt' -Raw
$headers = @{ Authorization = 'Bearer ' + $token.Trim() }

# 健康检查
Invoke-RestMethod 'http://127.0.0.1:19876/v1/health' -Headers $headers

# 提交
$body = @{ request_id = 'ps-001'; source = 'powershell'; model = 'qwen21_turbo';
           mode = 'text'; prompt = 'a quiet lake at dawn'; width = 512; height = 512 } | ConvertTo-Json
$job = Invoke-RestMethod 'http://127.0.0.1:19876/v1/jobs' -Method Post -Headers $headers -Body $body -ContentType 'application/json'

# 等待
Invoke-RestMethod ("http://127.0.0.1:19876/v1/jobs/{0}/wait?timeout=30" -f $job.job_id) -Headers $headers

# 取字节存文件
Invoke-WebRequest ("http://127.0.0.1:19876/v1/images/{0}" -f $imgId) -Headers $headers -OutFile 'D:\out.png'
```

## 附录 C：术语

| 术语 | 含义 |
|---|---|
| 引擎 | 本机 ComfyUI 进程，端口 8189 |
| 工作台 / GUI | `本地生图工作台.ps1` 的窗口 |
| 任务 | `jobs\<id>\` 一个目录 = 一次提交 |
| 结果 | 任务里的一张图，API 里是 `image_id` |
| 预设 | 画风/人物/表情等英文片段，`catalog.json` 里带稳定 ID |
| 参考图档位 | `ref_preset`，控制"改多深" |
| 人工暂停 | 用户按下的队列暂停，优先级最高 |