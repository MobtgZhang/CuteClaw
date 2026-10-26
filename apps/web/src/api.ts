import type { ChatReply, DrcReport, Health, JsonValue, Metrics, PluginInfo, Session, ToolDef } from "./types";

const base = (import.meta.env.VITE_API_BASE as string | undefined) ?? "";

function url(path: string): string {
  return `${base}${path}`;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url(path), {
    ...init,
    headers: { accept: "application/json", ...(init?.headers ?? {}) },
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${text || response.statusText}`);
  }
  return JSON.parse(text) as T;
}

export const api = {
  health: () => request<Health>("/api/health"),
  sessions: () => request<Session[]>("/api/sessions"),
  tools: () => request<ToolDef[]>("/api/tools"),
  plugins: () => request<PluginInfo[]>("/api/plugins"),
  metrics: () => request<Metrics>("/api/metrics"),
  chat: (session: string, message: string) =>
    request<ChatReply>("/api/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session, message }),
    }),
  drc: (project: JsonValue) =>
    request<DrcReport>("/api/drc", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(project),
    }),
  kicad: (text: string) =>
    request<JsonValue>("/api/kicad", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text }),
    }),
};
