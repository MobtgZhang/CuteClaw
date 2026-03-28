# 路线图（非承诺）

## 已有

- CLI：`init` / `demo` / `status` / `export` / `import` / `evolve` / `validate` / `task` / `invoke` / `config` / `working` / `fact` / `serve`
- 库：`ClawRuntime`、`persist`（schema v1）、`evolution`、`metrics`、`config`
- 本地 Web：`web/`（**默认** Vite + **`cuteclaw serve` 进程内 `/api/*`**）；可选 Node Fastify（`npm run server`，子进程调 CLI）
- `store.json` 旁路咨询锁（`*.lock`，不支持锁的平台静默跳过）

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
