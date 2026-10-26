# 前端（Vue 3 + TypeScript）

前端在 **`apps/web`**，构建产物 `apps/web/dist` 是 `cuteclaw serve` 的默认静态根。遗留的 React 控制台仍在 `web/`，两者互不影响。

## 结构

| 路径 | 内容 |
|------|------|
| `apps/web/src/main.ts` | 挂载入口 |
| `apps/web/src/App.vue` | 面板布局 |
| `apps/web/src/api.ts` | REST 调用（health / sessions / tools / plugins / metrics / chat / drc / kicad） |
| `apps/web/src/sse.ts` | `POST /api/chat/stream` 流式事件 |
| `apps/web/src/ws.ts` | `GET /api/ws` WebSocket（文本帧即 JSON-RPC） |
| `apps/web/src/types.ts` | 与 Zig 响应一致的类型 |
| `apps/web/src/components/` | ChatPanel、ToolPanel、PluginPanel、ValidationPanel、MetricsPanel |

## 开发与构建

```bash
cd apps/web
npm install        # make app-install
npm run build      # make app-build（vue-tsc --noEmit && vite build）
npm run dev        # make app-dev（Vite 5173，/api 代理到 8788）
```

端口环境变量：**`VITE_API_PORT`**（默认 `8788`）。

## 服务端点

`cuteclaw serve` 提供：

- `GET /api/health`、`GET /api/sessions`、`GET /api/tools`、`GET /api/plugins`、`GET /api/metrics`
- `POST /api/chat`、`POST /api/chat/stream`（SSE）、`POST /api/drc`、`POST /api/kicad`
- `GET /api/ws` — WebSocket 升级，文本帧按 JSON-RPC 处理
- 其余路径走静态资源（拒绝 `..` 越界）

WebSocket 升级后使用直接的 socket 读写（不经过 `std.Io` 缓冲），粘包、ping/pong 与 close 回显均按 RFC 6455 处理；握手 GUID 为 `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`。
