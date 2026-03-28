# Web 界面与 CuteClaw

## 推荐开发方式（Zig 后端 + Vite）

`make web-dev-zig`（或 `cd web && npm run dev`，**需已 `zig build`**）会并行启动：

- **Vite**（默认 `http://127.0.0.1:5173`）：Agent 风格前端；`/api/*` 代理到 Zig，`/agent/*` 代理到 Agent 宿主。
- **`cuteclaw serve`**（默认 `http://127.0.0.1:8788`）：`/api/*`（store、config、evolve 等）。
- **Agent 宿主**（`tsx watch server/agent-host.ts`，默认 `http://127.0.0.1:8790`）：`/agent/*`（`./cache`、Skill 扫描、SSE 聊天、**function calling → `cuteclaw agent-tool`**）。控制台「执行轨」与 `task_plan` 见 [agent-execution-flow.zh.md](agent-execution-flow.zh.md)；布局与 cache 见 [agent-cache.md](agent-cache.md)、工具见 [agent-tools.md](agent-tools.md)。

端口环境变量：**`VITE_API_PORT`**（默认 `8788`）、**`VITE_AGENT_PORT`** / **`CUTECLAW_AGENT_PORT`**（默认 `8790`）、Zig **`CUTECLAW_SERVE_PORT`** / **`--port`**。

若聊天中模型会调用工具，请确保 **`zig build` 已生成 `cuteclaw`**；宿主通过 **`CUTECLAW_BIN`**（可选）定位可执行文件，与 `web/server/cuteclaw.ts` 一致。

访问日志与启动信息在 **`cuteclaw serve` 的 stderr**；设置 **`CUTECLAW_LOG=error`** 可关闭按请求的访问日志，仅保留错误。

可选 **`CUTECLAW_ROOT`**：与旧版 Node 脚本一致，用于健康检查 JSON 中的 `cuteclawRoot`；未设置时使用进程当前工作目录的 `realpath(".")`。

## 可选：仅 Node API（遗留）

仍可通过 `cd web && npm run server` 启动 Fastify（默认 **8787**），由子进程调用 `cuteclaw` CLI。此时请将 `web/vite.config.ts` 中代理端口改为 **8787**，或设置 `VITE_API_PORT=8787`。`web/server/writeLock.ts` 仅在 **单个 Node 进程** 内对写操作排队，**不会**约束其它终端里的 `cuteclaw`。

## 并发写 store 的风险

`store.json` 由 CuteClaw 在 `evolve`、`task`、`invoke`、`import` 等路径更新。若 **终端 CLI** 与 **正在提供 HTTP 的 `cuteclaw serve`**（或 Node API）同时对同一文件写入，仍可能出现覆盖或短暂不一致。

自 Zig 侧起，CLI 与 `serve` 在读写默认 store 时还会尝试获取同目录下的 **`store.json.lock` 咨询锁**（见 `src/store_lock.zig`）。**仍无法**约束不尊重该锁的编辑器或其它程序。

**实践建议**：对同一数据目录只使用一个写者；多人或多工具共用 store 时，应明确串行策略。

## config 编辑

`PUT /api/config`（Zig `serve`）先将请求体写入临时文件，再用与 CLI 相同的 **`config.loadApiConfigFromPath`** 校验；失败时返回 400，**不会**覆盖现有 `config.json`。成功则原子写入目标路径。

CLI 的 `config show` / `config init` 仍是运维参考；若 schema 演进，需同步更新 `docs/format.md` 与 `web/src/types/config.v1.ts`。
