# 本地生图工作台 Agent 调用说明

适用于有本机命令执行或 HTTP 工具的 Codex、DeepSeek 等 agent。无需点击工作台控件。人和 agent 共用工作台队列，任务结果会显示在工作台中。

应用目录：本文件所在目录（安装后的 `<ComfyUI根目录>\QwenImageApp`）

Python：`<ComfyUI根目录>\python_embeded\python.exe`

## 最快调用方式

用上述 Python 执行 `QwenImageApp\agent_client.py`。所有文本响应都是 JSON，错误写到 stderr 并以非零退出。客户端自行读取本机令牌，不要复制令牌到提示词、命令参数或日志。

```text
agent_client.py start
agent_client.py models
agent_client.py presets --query 光影
agent_client.py characters --query 云堇
agent_client.py submit --model qwen21_turbo --prompt "清晨山间的一座木亭，自然光" --source codex --request-id codex-example-001
agent_client.py status job_...
agent_client.py wait job_... --timeout 30
agent_client.py image img_... --base64
agent_client.py cancel job_...
```

`start` 启动服务和可见工作台；`serve` 只确保服务已运行。已有工作台在线时不会再次打开窗口。后台任务等待较久时每次等待不超过 30 秒，继续按同一 job_id 查询，不要重新提交。

## Python 结构化调用（推荐复杂任务使用）

```python
import sys
APP = r'<ComfyUI根目录>\QwenImageApp'
sys.path.insert(0, APP)
from agent_client import Client

client = Client(APP)
client.start()
task = client.call('/v1/jobs', {
    'request_id': 'codex-task-001',  # 为一次真实意图生成唯一 ID；网络重试沿用此 ID
    'source': 'codex',              # 也可以是 deepseek 或其他来源名称
    'model': 'qwen21_turbo',
    'mode': 'text',
    'prompt': 'A wooden pavilion on a grassy hill at sunrise, natural light',
    'width': 512, 'height': 512, 'count': 1, 'seed': -1,
})
print(task['job_id'])
status = client.call('/v1/jobs/' + task['job_id'] + '/wait?timeout=30')
# 如果仍在 queued/running，继续等待同一任务。
# 完成后：image_id = status['results'][0]['image_id']
# png_bytes = client.call('/v1/images/' + image_id, raw=True)
```

复杂请求也可用 `submit --file request.json`（UTF-8）或 `submit --file -` 从 stdin 读取 JSON，避免 Shell 对 JSON 引号的转义影响。

## 上传与直接使用上一张结果改图

```python
import base64
# 外部参考图只需上传一次；返回 image_id，后续不再传本地路径。
uploaded = client.call('/v1/images', {'data_base64': base64.b64encode(reference_bytes).decode('ascii')})
# 如果参考上一任务的结果，直接使用它的 image_id，无需下载再上传。
edited = client.call('/v1/jobs', {
    'request_id': 'codex-edit-001', 'source': 'deepseek',
    'model': 'qwen21_turbo', 'mode': 'edit',
    'image_ids': [uploaded['image_id']],
    'prompt': 'Change the roof to blue. Preserve the building and viewpoint.',
    'resolution': 512, 'ref_mode': 'structure', 'ref_preset': 'normal',
})
```

图片接口默认返回真实图片字节；`?format=json` 返回图片元数据和 `data_base64`；`?format=metadata` 只返回元数据。CLI `image ID --raw` 输出原始字节，`--base64` 输出带数据的 JSON，默认只显示元数据。`--out FILE` 是可选导出，已有文件不会被覆盖。

图像数据是否能直接显示给模型，取决于 agent 的图像工具；无论是否显示，继续改图都可直接传 image_id。不要把不可访问的路径或仅含文件名的字符串当作图片数据。

## 提交参数

必填：`request_id`、`model`。提示词、预设或随机分类至少提供一种。

| 字段 | 约定 |
|---|---|
| source | 来源标签，默认 agent；队列显示此来源及 job_id 简写 |
| mode | text 或 edit；只允许模型公开支持的模式 |
| prompt / prompts | 单段文字或字符串数组；prompts 存在时优先；edit 仅一段要求 |
| preset_ids / character_ids | 从目录查询得到的稳定 ID 数组，合并到每段提示词 |
| random_categories | 如 style、expression；每张重新抽取，实际选项保存在结果元数据中 |
| negative_prompt | 默认空串；不会隐式使用人正在编辑的内容 |
| count | 每段 / 每张参考图的生成数量，正整数 |
| width / height | 默认 1024，各为 256～2048 且为 32 的倍数 |
| steps | 使用模型默认值；Turbo 固定 8 步 |
| cfg | 1～10；文生图用模型默认值，图生图默认 5 |
| seed | -1 随机，或 0～2^63-1；结果返回实际种子 |
| image_ids | 已登记图片 ID 数组，仅 edit 使用 |
| resolution | 图生图清晰度，512 / 1024 / 1536 |
| ref_mode | structure 修改原图，或 feature 参考元素 |
| ref_preset | structure: subtle/normal/redraw；feature: free/balanced/close |
| ref_element | character / pose / style / all |
| output | 可省略，采用工作台配置的输出文件夹；指定时必须为完整本机路径 |

参数省略时采用模型默认值；不会把人的角色、提示词或负面词偷偷混入 agent 请求。未知字段会报错，不会静默忽略拼写错误。

## HTTP 路由

服务发现：`QwenImageApp\agent_api\service.json`，默认 `http://127.0.0.1:19876`。
本机令牌：同目录 `token.txt`，请求头 `Authorization: Bearer <token>`。`Client` 自动处理这两项；禁止把 token 写进 URL。服务不接受浏览器 Origin，也不监听局域网地址。

| 方法 | 路径 | 功能 |
|---|---|---|
| GET | /v1/health | 版本、工作台在线与人工暂停状态 |
| GET | /v1/models | 模型、模式、默认值、参数约束 |
| GET | /v1/presets?query=... | 预设名称、分类、文本与 ID |
| GET | /v1/characters?query=... | 角色名称、作品、性别、英文标签与 ID |
| POST | /v1/images | 上传 JSON data_base64，返回图片 ID |
| POST | /v1/jobs | 校验并提交任务，返回 job_id |
| GET | /v1/jobs/ID | 状态、进度、阻塞原因、结果和错误 |
| GET | /v1/jobs/ID/wait?timeout=30 | 最多等待 30 秒的状态变化 |
| POST | /v1/jobs/ID/cancel | 取消该 API 任务，body 为 {} |
| GET | /v1/images/ID | 真实图片数据或指定格式的响应 |

## 状态、重试和人的控制权

- queued/running/done/error/cancelled。`blocked_reason` 可能为 queue_paused、workbench_offline、workbench_restarted。
- 相同 request_id 和相同请求只产生一个任务，包括并发重试；同一 ID 改变内容返回 409。修改意图或重新生成请使用新的 request_id。
- 人工暂停时任务可排队，但 agent 不会擅自恢复队列。取消等待中的任务不影响其他项；取消正在执行的任务会等待引擎确认并暂停后续队列。
- 参数错误通常是 400；无令牌 401；未知图片/任务 404；图片被删除或替换 410；超限 413；工作台离线时新提交 503。
- 错误 JSON 为 `error: {code, message, field, retryable}`。任务生成失败的错误位于任务状态响应的 error 字段，HTTP 状态查询本身仍为 200。
- 结果包含 image_id、读取地址、实际尺寸、种子、模型等；真实执行器另记录最终提示词、步数、引导强度和逐张随机选项。部分成功仍保留已完成图片。
- 图片被删除或同名替换后，旧 ID 不会返回另一张图，而会返回 410。
- 请求/资产登记与真实执行结果落盘。服务重启可继续查询；工作台关闭或重启时未开始的任务不会被悄悄重跑，状态会报告阻塞原因。工作台原有人工队列仍是会话队列。
- agent 结果遵循主预览的人工翻页状态；独立大图窗口始终不被自动切图。人的编辑框不会因 agent 提交而改变。

## Codex / DeepSeek 本机 agent 的建议规则

1. 先读 models 和需要的预设/角色目录，再提交有效 ID。
2. 用 source 标记来源，记录返回的 job_id 和 image_id。
3. 轮询等待同一任务，看到人工暂停时报告给人，不擅自修改全局队列。
4. 有图片结果时使用图片读取接口交给自己的图像工具；后续改图引用 image_id。
5. 不模拟界面点击，不直接篡改工作台设置，不为重试生成新的 request_id。

这里是通用 HTTP / CLI 接口，不依赖 agent 使用哪个大模型；没有额外修改 Codex 或 DeepSeek 的全局工具设置，也没有安装 MCP 服务。
