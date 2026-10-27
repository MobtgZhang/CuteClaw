# CuteClaw 文档索引

项目总览见 [../README_CN.md](../README_CN.md)（English: [../README.md](../README.md)）。

| 文档 | 内容 |
|------|------|
| [architecture.md](architecture.md) | 模块职责、数据流、CLI 子命令、与宿主集成要点 |
| [format.md](format.md) | 快照 JSON（schema v1）与提议 JSON 字段说明 |
| [quickstart.md](quickstart.md) | 构建、测试、常用命令 |
| [agent-cache.md](agent-cache.md) | Agent UI 的 `./cache` 布局与 ClawHub 技能目录说明 |
| [agent-tools.md](agent-tools.md) | 原子 Agent 工具（`cuteclaw agent-tool`）、宿主 function calling、安全开关 |
| [agent-execution-flow.zh.md](agent-execution-flow.zh.md) | Web Agent 执行轨、`task_plan` / `plan_update`、`agentTrace` 与会话持久化 |
| [web-ui.md](web-ui.md) | Web 与 Zig / Agent 宿主端口与开发方式 |
| [design-agent.md](design-agent.md) | 专业领域设计 Agent（PCB / 外壳）：模块、工具面、硬约束优先、进化引擎 |
| [graph-flow.md](graph-flow.md) | Graph Flow / Graph Loop 执行模型：依赖图、工作形状、硬门、回路护栏、54 项技能目录、plan-3 五类工具映射与 GitHub 来源 |
| [agent-loop.md](agent-loop.md) | Agent Loop 运行期规则：二元终止条件、hook 只能收紧、审批与不可逆动作、压缩审计、检查点与回退、子代理边界、`SKILL.md` 与 DSH manifest 共存 |
| [dsh-plugins.md](dsh-plugins.md) | DeepSeek Harness（Cordis）插件兼容：manifest 解析、桥接协议、JSON-RPC 错误码、权限 |
| [vue-app.md](vue-app.md) | Vue 3 + TypeScript 工作台（`apps/web`）：结构、构建、服务端点、WebSocket |
