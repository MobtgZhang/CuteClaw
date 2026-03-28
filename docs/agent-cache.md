# Agent 本地目录（`./cache`）与项目划分

CuteClaw 的 **Agent 控制台**（`web/`）通过 **Agent 宿主**（`web/server/agent-host.ts`，默认 `127.0.0.1:8790`）读写数据。默认根路径为 **`<仓库根>/cache`**，可在 UI **设置** 中修改 `cacheRoot`。

## 定稿：会话与 Skill 均按项目隔离

- 每个 **项目**（`projectId`，如 `default`、`my-app`）拥有独立的 **会话、技能、记忆** 目录，与 ChatGPT「项目」类似。
- **无全局 Skill 目录**：旧版扁平路径会在首次启动宿主时 **一次性迁移** 到 `projects/default/`（若该目录尚不存在）。

## 目录布局（`{cacheRoot}` 为有效数据根）

| 路径 | 说明 |
|------|------|
| `cache/settings.json` | 固定位于仓库 `cache/` 下，保存 `cacheRoot`、模型、`temperature` / `top_p`、`agentToolMaxRounds`、API Key 标记等（**不按项目分**） |
| `{cacheRoot}/projects/<projectId>/skills/` | 该项目下的 ClawHub / OpenClaw 技能包 |
| `{cacheRoot}/projects/<projectId>/memory/` | 该项目下的笔记或片段 |
| `{cacheRoot}/projects/<projectId>/history/sessions/*.jsonl` | 该项目下的会话事件 |
| `{cacheRoot}/projects/<projectId>/_project.json` | 可选元数据，如 `{ "title": "显示名" }` |

## API 中的项目作用域

- 查询参数 **`?project=<projectId>`**（或请求头 **`X-Project-Id`**）指定当前项目；缺省为 **`default`**。
- **`GET /agent/projects`**：列出项目；保证存在 `default`。
- **`POST /agent/projects`**：body `{ "id": "...", "title?": "..." }` 创建新项目目录。

## 与 ClawHub 技能对齐

将技能放入 **`{cacheRoot}/projects/<当前项目>/skills/<技能名>/`**（内含 `SKILL.md` 或 `claw.json` 等），控制台左侧 Skills 列表会按项目扫描。

此外，**`skills/` 根目录下**可直接放 **`*.md`** 单文件技能（`id` 为去掉后缀的文件名）；若与同名的**文件夹**技能并存，则以文件夹为准。保存会话时若尚未命名，会用**首条用户消息**自动生成侧栏标题（可在侧栏菜单中重命名）。

## 端口（`npm run dev`）

- **5173**：Vite 前端  
- **8788**：`cuteclaw serve`（`/api/*`）  
- **8790**：Agent 宿主（`/agent/*`）  

环境变量：`CUTECLAW_AGENT_PORT`、`VITE_AGENT_PORT`。

## 系统提示与内置说明

宿主从仓库根 **`prompts/`** 读取并拼接系统消息：

- **`agent-system.zh.md`**：主模板；`{{SKILL_SUMMARY}}` 由当前项目下的技能摘要替换。
- **`builtin-host-capabilities.zh.md`**（可选）：说明项目划分、技能与 UI 边界、**真实可调用的原子工具**由 Zig `agent-tool` 提供等；用于对齐模型预期。详见 [agent-tools.md](agent-tools.md)。

流式聊天中，若上游在 `choices[].delta` 里返回 **`reasoning_content` / `reasoning` / `thought` / `thinking`** 等字符串字段，宿主会单独以 SSE 事件 **`thinking`** 推给前端，与正文 `delta` 分离；前端以 **Markdown** 渲染思考流。

宿主在 **`POST /agent/chat`** 中会为模型注册 **OpenAI 兼容的 `tools`**，并在流式响应中解析 **`tool_calls`**；工具在子进程中执行 **`cuteclaw agent-tool`**（见 [agent-tools.md](agent-tools.md)）。执行过程可通过 SSE **`step`** 事件（如 `tool_call` / `tool_result`）观察。

## Zig CLI 与 memory

与上述布局一致，可用纯 Zig 命令管理 memory（无需 TypeScript）：

```bash
zig build run -- memory --cache cache --project default list
zig build run -- memory --cache cache --project default get notes/hello.md
```

详见 `zig build run -- memory` 帮助。
