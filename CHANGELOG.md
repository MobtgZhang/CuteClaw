# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号与 `src/version.zig` / `build.zig.zon` 一致。

## [Unreleased]

### Added

- 专业设计核（只做 PCB 与产品外壳，不做通用任务）：`src/design/`（工程、约束、几何、PCB/飞线、DRC、工具面）与 `src/adapters/`（KiCad `.kicad_pcb`、FreeCAD、STEP）
- 纯 Zig Agent Host：`src/core/`（Agent 主循环、OpenAI/Anthropic 兼容 LLM 客户端、会话与令牌预算、工具注册表、Cordis 风格事件总线）
- DeepSeek Harness（Cordis，manifestVersion 1）插件兼容：`src/plugins/`（manifest、权限、内核、MCP、桥接调用）+ `bridges/deepseek-harness/bridge.mjs`
- Harness² 式进化引擎：`src/evolution/`（Propose–Probe–Compose–Evaluate–Promote），guardrails 与硬约束不可被自进化改写
- CLI 子命令：`chat`（单轮与交互式 REPL）、`plugin`、`design`
- `serve`：`/api/chat`、`/api/chat/stream`（SSE）、`/api/drc`、`/api/kicad`、`/api/ws`（WebSocket，文本帧按 JSON-RPC 处理），静态根默认 `apps/web/dist`
- Vue 3 + TypeScript 工作台 `apps/web`（遗留 React 控制台仍在 `web/`）
- 数据契约 `schemas/`、基准 `benchmarks/pcb/`、示例插件 `skills/`
- Make 入口：`check`、`dsh`、`benchmark`、`drc`、`schemas`、`live-chat`、`app-install`、`app-build`、`app-dev`
- 文档：`docs/design-agent.md`、`docs/dsh-plugins.md`、`docs/vue-app.md`

### Changed

- CLI 用法与错误文本在退出前 flush：此前写入缓冲 writer 的用法提示会随 `std.process.exit` 丢失
- `websocket.zig` 的 `Frame` 记录 `consumed`，长连接改用直接 socket 读写（`std.Io` 缓冲在长连接上会误报 EOF 并延迟写入）

## [0.1.1] - 2026-03-28

### Changed

- 语义版本与 Web Agent 控制台对齐为 0.1.1；宿主支持删除项目与会话跨项目移动；侧栏三栏布局与消息气泡角标操作等（详见 `web/` 变更）。

## [0.2.0] - 2026-03-24

### Added

- CLI：`config validate`；`working show|set`；`fact add`；`serve`（仅 `127.0.0.1`，`GET /health`、`/store`、`/status`，`POST /evolve`）
- 对默认 `store` 路径使用 `store.json.lock` 咨询锁（与 CLI 写路径一致）
- 文档：`docs/cli-exit-codes.md`、`docs/embedding.md`、`docs/roadmap.md`；`testdata/minimal_store_v1.json`；`tests/cli_smoke.sh`；`zig build fmt`
- CI：`.github/workflows/cuteclaw.yml`（Zig 测试 + fmt + 冒烟 + `web` 构建）
- Web：`PUT /api/config` 写入前调用 `cuteclaw config validate`（临时文件 + `CUTECLAW_CONFIG`）

### Changed

- `status` 在无法加载 store 时以退出码 2 失败；`import` JSON 解析失败时退出码 2 并提示 `docs/format.md`
- 帮助文本补充退出码说明
