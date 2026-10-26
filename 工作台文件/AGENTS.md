# 本地生图工作台调用入口

需要调用本项目生图或改图时，先读同目录 `AGENT_API.md`。
使用 `agent_client.py` 或本机 HTTP 接口，避免鼠标点击和直接修改设置。
复用现有工作台队列，记录 job_id / image_id，后续改图直接引用 image_id。
人工暂停优先；任务重试复用 request_id；不得输出本机令牌。
