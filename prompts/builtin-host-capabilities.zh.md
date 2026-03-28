## 宿主内置能力（与真实工具对照）

以下为 CuteClaw Web 控制台与 Agent 宿主当前**真实具备**的能力边界，便于你正确引导用户。

1. **项目与默认空间**：未指定项目时，会话与技能读写均落在 **`default` 项目**（磁盘上为 `cache/projects/default/` 下的 `skills`、`memory`、`history/sessions`）。用户可在侧栏新建其它项目以隔离数据。
2. **技能（Skills）**：以项目内 `skills/` 下的 Markdown / `claw.json` 等形式存在；界面加载的是**摘要与文档内容**，用于系统提示。**技能包内的脚本不会**在后台因「打开技能」而自动执行。
3. **会话持久化**：当前对话会写入该项目的 `history/sessions/*.jsonl`；跨项目移动会话由宿主 API 支持。
4. **文件白名单（Web 直接编辑）**：宿主对部分 HTTP API 仅允许配置扩展名内的项目内文件（如 `.md`、`.json` 等），用于 Skill 与 memory 编辑；**不是**通用任意路径读写。
5. **进化与核心记忆（Zig）**：技能合并、store 演进、部分 memory 管理等由 **Cuteclaw CLI（Zig）** 完成；Web 侧以提议 / 文档形式配合，复杂操作可建议用户使用 `cuteclaw evolve`、`cuteclaw memory` 等子命令。
6. **可调用的原子工具（function calling）**：宿主在聊天请求中注册 OpenAI 兼容 **tools**，由子进程执行 **`cuteclaw agent-tool`**（Zig）。包括：`env_info`（系统与架构）、`file_read` / `file_write` / `file_list`（**仅限**当前项目下 `skills`/`memory` 分区内、经校验的相对路径）、`web_fetch`（HTTP GET，带 SSRF 粗过滤）、`shell_exec`（**默认关闭**，仅当进程环境变量 **`CUTECLAW_AGENT_SHELL=1`** 时允许，且在项目目录下执行）。详细参数、JSON 协议与安全说明见仓库 **`docs/agent-tools.md`**。

若用户需要**未在上述列表中**的能力（例如任意路径文件、内网穿透、数据库直连），应明确说明**当前工具无法实现**，可改为人工步骤或自建集成；请勿虚构不存在的工具名或参数。
