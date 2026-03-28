# Agent 原子工具（Zig `agent-tool` + 宿主 function calling）

CuteClaw 在 **Zig CLI** 中实现一组**白名单原子工具**，由 **Agent 宿主**（`web/server/agent-host.ts`）在 OpenAI 兼容的 **`/agent/chat`** 流式对话里以 **function calling** 方式调用。执行路径为：宿主 → 子进程 **`cuteclaw agent-tool`**（stdin 一行 JSON）→ stdout **一行 JSON**。

设计目标：在**固定能力边界**内给模型可用的「读/写项目 cache、拉取公开网页、可选 shell」等能力，路径与网络均做强校验；与 [GenericAgent](https://github.com/lsdefine/GenericAgent) 一类「少量原子工具 + 循环」的思路一致，但工具集与策略以本仓库实现为准。

## 依赖与可执行文件

- 宿主通过 `web/server/cuteclaw.ts` 的 **`runCuteclaw`** 启动子进程；需本机已 **`zig build`**，且可找到 `cuteclaw` 二进制。
- 环境变量 **`CUTECLAW_BIN`**：显式指定可执行文件路径（与 `npm run server` / 开发文档一致）。
- 若模型发起工具调用但二进制缺失或执行失败，工具结果会以 JSON 错误形式回传给模型（见下文响应格式）。

## CLI：`cuteclaw agent-tool`

从 **stdin** 读取**至多约 1MiB** 的 UTF-8 JSON，向 **stdout** 打印**一行** JSON（末尾换行），错误场景也尽量走 stdout 的 JSON，便于机器解析；**stderr** 保留给人读的诊断（如 JSON 根类型错误时可能直接退出）。

### 请求体（stdin JSON 对象）

| 字段 | 必填 | 说明 |
|------|------|------|
| `tool` | 是 | 工具名，见下表 |
| `cache_root` | 是 | 解析后的 cache 根目录绝对路径（与 UI `cacheRoot` / `resolveCacheRoot` 一致） |
| `project` | 否 | 项目 id，默认 `default` |
| `skills_subdir` | 否 | 默认 `skills` |
| `memory_subdir` | 否 | 默认 `memory` |
| `args` | 视工具而定 | JSON 对象；**`env_info` 可不提供 `args`**，其余工具必须提供对象（可为 `{}`） |

### 响应体（stdout 一行 JSON）

| 字段 | 说明 |
|------|------|
| `ok` | `true` / `false` |
| `result` | 成功时的负载（结构随工具变化） |
| `err` | 失败时的短字符串（注意：Zig 侧关键字限制，**不使用**键名 `error`） |

宿主 TypeScript 解析时以 **`err`** 为准。

### 工具一览

| 工具名 | 作用 | `args` 要点 |
|--------|------|-------------|
| `task_plan` | **仅宿主**：向 UI 推送任务规划（Todo 式步骤），**不**调用 Zig `agent-tool` | `thought`（可选），`steps`: `{ id, title, status, detail? }[]`；`status` 建议 `pending` / `in_progress` / `done` / `cancelled` |
| `env_info` | 返回 OS 与 CPU 架构 | 无；**无需** `args` 字段 |
| `file_read` | 读项目下 `skills` 或 `memory` 分区内文本文件 | `bucket`: `skills` \| `memory`，`rel`: 相对路径 |
| `file_write` | 写入同上（自动建父目录） | 同上 + `content` |
| `file_list` | 列出某 bucket 根或子目录条目 | `bucket`，`rel` 可选（空串表示根） |
| `web_fetch` | HTTP GET | `url`，可选 `max_bytes`（默认约 512KiB） |
| `shell_exec` | 在**项目目录** `…/projects/<project>/` 下执行命令 | `command`，可选 `timeout_ms`（默认 60000） |

**操作系统差异**（由 Zig / 子进程处理）：

- **Windows**：`cmd /C <command>`
- **Linux / macOS 等**：`/bin/sh -c <command>`

**`env_info` 的 `result` 示例**：`{ "os": "linux" \| "macos" \| "windows" \| "other", "arch": "x86_64" 等 }`

## 安全与限制

### 路径

- 仅允许访问 **`{cache_root}/projects/<project>/<skills_subdir|memory_subdir>/`** 下、由 `rel` 拼出的路径。
- `rel` **不得**包含 `..`、不得以 `/` 或 `\` 开头。
- 使用路径解析后的**前缀校验**，防止逃逸。

### `web_fetch`

- 拒绝 **`file:`** 等危险 scheme。
- 对 **localhost、回环与常见私网** 主机名做**粗粒度拦截**（具体实现见 `src/agent_tool_cli.zig`），降低 SSRF 风险；**不应**视为完整网络隔离。

### `shell_exec`

- **默认关闭**：仅当环境变量 **`CUTECLAW_AGENT_SHELL=1`** 时允许执行。
- 标准输出/标准错误有**上限**（当前实现约 256KiB 量级）；超时由宿主传入的 `timeout_ms` 与 Zig 侧**限时 kill** 配合实现。

### 宿主侧轮次上限

- `web/server/agent-host.ts` 中 **function 多轮**默认 **8**；可在 `cache/settings.json` / 控制台设置里调整 **`agentToolMaxRounds`**。**`-1`** 表示尽量多轮（宿主硬上限 **512**，防止死循环）。请求上游时还会带上 **`temperature`**、**`top_p`**（见设置）。

## 宿主集成要点

- **工具 schema** 与描述：`web/server/agent-tools.ts` 中的 **`AGENT_TOOLS_OPENAI`**，需与 Zig 行为保持语义一致。
- **SSE**：除原有 `delta`、`thinking` 外，工具调用与结果会以 **`step`** 事件推送，例如 `kind: "tool_call"`、`kind: "tool_result"`；模型调用 **`task_plan`** 时宿主会推送 **`kind: "plan_update"`**，详见 [agent-execution-flow.zh.md](agent-execution-flow.zh.md)。
- **流式 `tool_calls`**：宿主会合并分片 delta 中的 `tool_calls`，再一次性执行并进入下一轮对话。

## 手动调试示例

```bash
# 环境信息（可无 args）
echo '{"tool":"env_info","cache_root":"'"$(pwd)"'/cache","project":"default"}' \
  | ./zig-out/bin/cuteclaw agent-tool

# 列出 default 项目 skills 根目录（需先有 cache 布局）
echo '{"tool":"file_list","cache_root":"'"$(pwd)"'/cache","project":"default","args":{"bucket":"skills","rel":""}}' \
  | ./zig-out/bin/cuteclaw agent-tool
```

启用 shell（**慎用**）：

```bash
export CUTECLAW_AGENT_SHELL=1
echo '{"tool":"shell_exec","cache_root":"'"$(pwd)"'/cache","project":"default","args":{"command":"pwd"}}' \
  | ./zig-out/bin/cuteclaw agent-tool
```

## 相关源码

| 路径 | 说明 |
|------|------|
| `src/agent_tool_cli.zig` | 工具实现与 JSON 协议 |
| `src/main.zig` | 子命令 `agent-tool` 注册 |
| `web/server/agent-tools.ts` | OpenAI tools 定义 + `dispatchAgentTool` |
| `web/server/agent-host.ts` | `streamOpenAiChatWithTools`、`/agent/chat` |

## UI 相关特性（同一阶段交付）

- **执行轨（Cursor 式）**：每条助手消息上方展示「Agent 执行流」（思考、`task_plan`、工具调用等），历史轮次随 **`agentTrace`** 保留；见 [agent-execution-flow.zh.md](agent-execution-flow.zh.md)。
- **思考流**：若上游在 SSE 中返回 `thinking` 文本，前端以 **Markdown** 渲染（与助手正文组件一致），见 `web/src/pages/AgentConsole.tsx`。
- **对话区域宽度**：消息区与输入区使用 **`max-width: min(96vw, 56rem)`** 等样式，随视口变宽变窄，见 `web/src/App.css`（`.gpt-messages-inner`、`.gpt-compose-inner` 等）。
