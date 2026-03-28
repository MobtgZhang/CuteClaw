# CuteClaw

Zig 实现的**自进化 Agent 核心库 + CLI**（核心无内置图形 UI）：分层记忆、显式工作区、带门禁的技能进化、指标与审计、JSON 快照持久化。可选 **`web/`** 本地控制台（Vite + 小型 HTTP API）。不包含 LLM 调用与沙箱执行，便于由其它语言宿主集成。

## 要求

- [Zig](https://ziglang.org/) **0.15.2+**（与 `build.zig.zon` 中 `minimum_zig_version` 一致）

## 快速开始

```bash
cd CuteClaw
zig build
zig build test
zig build fmt        # zig fmt --check src/
zig build run -- help
zig build run -- init              # 创建 .cuteclaw/store.json
zig build run -- demo              # 演示并写入默认快照
zig build run -- status
zig build run -- evolve --file examples/proposal.json --policy auto_append_only --semver 0.3.0
zig build run -- config init
zig build run -- config show
zig build run -- config validate
zig build run -- serve --port 8788   # 仅 127.0.0.1，见 docs/architecture.md
zig build run -- memory --cache cache --project default list   # Agent cache 下 memory 文件（纯 Zig）
bash tests/cli_smoke.sh zig-out/bin/cuteclaw   # 冒烟（需先 zig build）
```

### Web 控制台（TypeScript）

见 [web/README.md](web/README.md) 与 [docs/web-ui.md](docs/web-ui.md)（并发与 `config` 写入说明）。开发：`cd web && npm install && npm run dev`（建议 Node 20+）。

- 快照：**`CUTECLAW_STORE`** / **`--store`** → 默认 `.cuteclaw/store.json`
- API 配置：**`CUTECLAW_CONFIG`** / **`--config`** → 默认 `.cuteclaw/config.json`（字段见 `docs/format.md`）

## 仓库布局

| 路径 | 说明 |
|------|------|
| `src/version.zig` | 语义版本单一来源 |
| `src/memory.zig` | 情景 / 语义 / 技能类型与 outcome 字符串互转 |
| `src/working.zig` | `WorkingSet` |
| `src/evolution.zig` | `Proposal`、静态门禁、`MergePolicy`、宽松 semver |
| `src/metrics.zig` | 任务信号、rollup、审计环、持久化种子 |
| `src/claw.zig` | `ClawRuntime` 聚合 |
| `src/persist.zig` | JSON schema v1、原子保存 |
| `src/config.zig` | 数据目录约定、`config.json` 解析与 API 密钥解析辅助 |
| `src/main.zig` | 子命令行入口 |
| `src/serve.zig` | `serve` 子命令的 HTTP 循环 |
| `src/store_lock.zig` | `store.json.lock` 咨询锁 |
| `examples/proposal.json` | `evolve` / `validate` 样例 |
| `examples/config.json` | `config.json` 字段样例 |
| `testdata/` | 黄金测试用 JSON |
| `tests/cli_smoke.sh` | CLI 冒烟脚本 |
| `web/` | 本地 Web UI + API |
| `prompts/` | Agent 系统提示模板（`agent-system.zh.md`，占位符 `{{SKILL_SUMMARY}}`），见 [prompts/README.md](prompts/README.md) |
| `docs/` | 架构、格式、上手、[退出码](docs/cli-exit-codes.md)、[嵌入](docs/embedding.md)、[路线图](docs/roadmap.md) |

详细字段与流程见 [docs/architecture.md](docs/architecture.md) 与 [docs/format.md](docs/format.md)。变更摘要见 [CHANGELOG.md](CHANGELOG.md)。
