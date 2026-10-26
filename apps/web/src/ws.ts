import type { JsonValue, RpcResponse } from "./types";

export type ConnectionState = "connecting" | "open" | "closed";

/** WebSocket 文本帧即 JSON-RPC：与 src/server/rpc.zig 完全一致。 */
export class RpcClient {
  private socket: WebSocket | null = null;
  private nextId = 1;
  private pending = new Map<number, (response: RpcResponse) => void>();
  private queue: string[] = [];

  constructor(readonly path: string = "/api/ws") {}

  connect(): void {
    if (this.socket && this.socket.readyState <= WebSocket.OPEN) return;
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(`${protocol}//${window.location.host}${this.path}`);
    this.socket = socket;

    socket.onopen = () => {
      for (const text of this.queue) socket.send(text);
      this.queue = [];
    };
    socket.onmessage = (event: MessageEvent) => {
      const response = JSON.parse(String(event.data)) as RpcResponse;
      const resolve = this.pending.get(response.id);
      if (resolve) {
        this.pending.delete(response.id);
        resolve(response);
      }
    };
    socket.onclose = () => {
      this.pending.clear();
      this.socket = null;
    };
  }

  call(method: string, params?: JsonValue): Promise<RpcResponse> {
    const id = this.nextId++;
    const frame = JSON.stringify({ jsonrpc: "2.0", id, method, params: params ?? null });

    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      this.queue.push(frame);
      this.connect();
    } else {
      this.socket.send(frame);
    }

    return new Promise<RpcResponse>((resolve) => this.pending.set(id, resolve));
  }

  close(): void {
    if (this.socket) this.socket.close();
    this.socket = null;
  }

  state(): ConnectionState {
    if (!this.socket) return "closed";
    if (this.socket.readyState === WebSocket.OPEN) return "open";
    if (this.socket.readyState === WebSocket.CONNECTING) return "connecting";
    return "closed";
  }
}
