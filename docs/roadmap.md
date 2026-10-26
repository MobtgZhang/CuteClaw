# 路线图（非承诺）

## 已有

- CLI：`init` / `demo` / `status` / `export` / `import` / `evolve` / `validate` / `task` / `invoke` / `config` / `working` / `fact` / `serve` / `chat` / `plugin` / `design`
- 库：`ClawRuntime`、`persist`（schema v1）、`evolution`、`metrics`、`config`
- 本地 Web：`web/`（**默认** Vite + **`cuteclaw serve` 进程内 `/api/*`**）；可选 Node Fastify（`npm run server`，子进程调 CLI）
- `store.json` 旁路咨询锁（`*.lock`，不支持锁的平台静默跳过）

### 专业设计核（已完成）

- **只做专业领域**：PCB 与产品外壳（CAD），不做通用任务 Agent。见 [design-agent.md](design-agent.md)
- 纯 Zig Agent Host：`src/core/`（agent 主循环、LLM 客户端、会话、工具注册表、事件总线），无第三方依赖
- 设计引擎：`src/design/`（工程、约束、几何、PCB/飞线、DRC 判定、工具面）；硬约束先淘汰再按代价排序
- 适配器：`src/adapters/`（`.kicad_pcb`、FreeCAD 文档、STEP）
- 进化引擎（Harness² 的 Propose–Probe–Compose–Evaluate–Promote）：`src/evolution/`，guardrails 与硬约束不可被自进化改写
- 插件兼容（DeepSeek Harness / Cordis，manifestVersion 1）：`src/plugins/` + `bridges/deepseek-harness/bridge.mjs`，见 [dsh-plugins.md](dsh-plugins.md)
- 权限与工作区边界：`src/sandbox/policy.zig`（越界读取直接拒绝）
- 前端：Vue 3 + TypeScript 工作台 `apps/web`，见 [vue-app.md](vue-app.md)；`serve` 静态根默认 `apps/web/dist`
- 数据契约：`schemas/`（design_task / tool_result / evolution_record）；基准：`benchmarks/pcb/`
- 测试入口：`make check`（build + test + smoke + dsh + benchmark + drc + schemas），`make live-chat` 用测试 API 跑真实对话

## 与 GenericAgent / OpenClaw 的对照（分阶段，非承诺）

| 方向 | CuteClaw 现状 | 可演进 |
|------|---------------|--------|
| 分层记忆 / 工作区 | 情景、技能、事实、`WorkingSet`；进化审计与 rollup | 与 [GenericAgent](https://github.com/lsdefine/GenericAgent) 式 L0/L2/L3 叙事对齐的文档与字段扩展（仍保持核内无 LLM） |
| 原子工具 + 循环 | 核外由宿主实现；核内仅确定性合并与持久化 | 可选 **宿主 Agent 循环**参考 OpenClaw 编排，经 HTTP/CLI 写入本核 |
| 自我进化 | `evolve` 门禁 + 指标 | Skill 固化路径已与「提议—检查—合并—观测」一致；可加强运行时「工具结晶」桥接规范 |
| 观测与运维 | `serve` 访问日志、stderr、`CUTECLAW_LOG` | TLS、鉴权、流式 `evolve`、结构化日志落盘 |
| 记忆检索 | 无向量检索 | 可选外挂向量索引，本库保持 **JSON 快照 + 显式 API** 边界 |

## 可能方向

- **Schema v2**：显式迁移工具与版本协商字段
- **配置**：CLI 与 Zig `PUT /api/config` 已共用解析逻辑；可再暴露「仅校验」专用端点供其它宿主调用
- **serve**：TLS、鉴权、流式 `evolve` 日志
- **测试**：更重的集成测试（多进程锁、HTTP 契约）
