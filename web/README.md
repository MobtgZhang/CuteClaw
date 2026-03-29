# CuteClaw Web 控制台

本地 **Vite + React + TypeScript** 前端。默认 **`npm run dev`** 同时启动：**Vite**（5173）、**`cuteclaw serve`**（8788）、**Agent 宿主**（8790，`server/agent-host.ts`）。`/api/*` → Zig，`/agent/*` → 宿主（`./cache`、聊天流式）。可选仅用 Node **`npm run server`**（8787）作为旧版 API。

可选：仅 Node API（`npm run server`，默认 `127.0.0.1:8787`，子进程调 CLI）——请将 `VITE_API_PORT=8787` 或改 `vite.config.ts` 代理端口。

## 开发与运行

1. 在仓库根目录：`zig build`（生成 `zig-out/bin/cuteclaw`）。
2. 在本目录：

```bash
cd web
npm install
npm run dev
```

浏览器打开默认 `http://127.0.0.1:5173`。

仓库根目录也可用：`make web-dev-zig`（先 `zig build` 再 `npm run dev`）。

### 环境变量

| 变量 | 说明 |
|------|------|
| `VITE_API_PORT` | Vite 代理 Zig `/api`，默认 **8788** |
| `VITE_AGENT_PORT` / `CUTECLAW_AGENT_PORT` | Agent 宿主端口，默认 **8790** |
| `CUTECLAW_SERVE_PORT` / `cuteclaw serve --port` | Zig HTTP 监听端口 |
| `CUTECLAW_LOG` | `error` 时关闭按请求访问日志，仅 stderr 错误 |
| `CUTECLAW_STORE` / `CUTECLAW_CONFIG` / `CUTECLAW_ROOT` | 与 CLI 相同 |
| `CUTECLAW_BIN` | 仅 **`npm run server`**（Node）子进程需要；`npm run dev` 使用 `../zig-out/bin/cuteclaw` |
| `CUTECLAW_API_PORT` | 仅 Node `server/index.ts` 监听端口，默认 **8787** |

单独启动 Node API：`npm run server`。

生产构建前端：`npm run build`，静态资源在 `dist/`。生产可只部署 **`cuteclaw serve` + 静态 `dist/`**，由反向代理把浏览器 `/api` 转到本机 8788；若沿用 Node API，则仍按原 Fastify 方案部署。

## 并发与数据安全

- **CLI 与正在跑的 `cuteclaw serve` 同时写同一 `store.json` 仍有风险**。Zig 使用咨询锁 `store.json.lock`，无法约束所有工具。
- 默认 **`npm run dev`** 下单进程 Zig 已串行处理 HTTP 写路径；旧版 Node API 的 `WriteLock` 仅在单 Node 进程内有效。

详见 [docs/web-ui.md](../docs/web-ui.md)。
