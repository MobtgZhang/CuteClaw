<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from "vue";
import { api } from "./api";
import { streamChat } from "./sse";
import { RpcClient, type ConnectionState } from "./ws";
import ChatPanel from "./components/ChatPanel.vue";
import MetricsPanel from "./components/MetricsPanel.vue";
import PluginPanel from "./components/PluginPanel.vue";
import ToolPanel from "./components/ToolPanel.vue";
import ValidationPanel from "./components/ValidationPanel.vue";
import type { ChatEntry, DrcReport, Health, JsonValue, Metrics, PluginInfo, SseEvent, ToolDef } from "./types";

const session = ref("web");
const entries = ref<ChatEntry[]>([]);
const health = ref<Health | null>(null);
const tools = ref<ToolDef[]>([]);
const plugins = ref<PluginInfo[]>([]);
const metrics = ref<Metrics>({ skills: [] });
const report = ref<DrcReport | null>(null);
const busy = ref(false);
const connection = ref<ConnectionState>("closed");
const rpcNote = ref("");

let nextId = 1;
const rpc = new RpcClient();

function field(data: JsonValue, key: string): JsonValue {
  if (data === null || typeof data !== "object" || Array.isArray(data)) return null;
  return (data as Record<string, JsonValue>)[key] ?? null;
}

function text(data: JsonValue, key: string): string {
  const value = field(data, key);
  return typeof value === "string" ? value : "";
}

function number(data: JsonValue, key: string): number {
  const value = field(data, key);
  return typeof value === "number" ? value : 0;
}

function flag(data: JsonValue, key: string): boolean {
  const value = field(data, key);
  return typeof value === "boolean" ? value : false;
}

function push(entry: Omit<ChatEntry, "id">): ChatEntry {
  const item: ChatEntry = { id: nextId++, ...entry };
  entries.value.push(item);
  return item;
}

function handleEvent(event: SseEvent): void {
  const data = event.data;

  if (event.kind === "delta" || event.kind === "reasoning") {
    const last = entries.value[entries.value.length - 1];
    const chunk = text(data, "text");
    if (last && last.role === "assistant") {
      last.text += chunk;
    } else {
      push({ role: "assistant", text: chunk });
    }
    return;
  }

  if (event.kind === "tool_call") {
    const name = text(data, "name");
    push({ role: "system", tool: name, text: `调用 ${name}：${text(data, "arguments")}` });
    return;
  }

  if (event.kind === "tool") {
    push({ role: "tool", tool: text(data, "tool"), ok: flag(data, "ok"), text: text(data, "content") });
    return;
  }

  if (event.kind === "done") {
    push({
      role: "assistant",
      text: text(data, "text"),
      rounds: number(data, "rounds"),
      tokens: number(data, "prompt_tokens") + number(data, "completion_tokens"),
    });
  }
}

async function send(text2: string): Promise<void> {
  push({ role: "user", text: text2 });
  busy.value = true;
  try {
    await streamChat(session.value, text2, handleEvent);
  } catch (error) {
    push({ role: "system", text: `请求失败：${(error as Error).message}` });
  } finally {
    busy.value = false;
  }
}

async function runDrc(project: JsonValue): Promise<void> {
  busy.value = true;
  try {
    report.value = await api.drc(project);
  } catch (error) {
    push({ role: "system", text: `DRC 失败：${(error as Error).message}` });
  } finally {
    busy.value = false;
  }
}

async function refresh(): Promise<void> {
  try {
    const [h, t, p, m] = await Promise.all([api.health(), api.tools(), api.plugins(), api.metrics()]);
    health.value = h;
    tools.value = t;
    plugins.value = p;
    metrics.value = m;
  } catch (error) {
    rpcNote.value = `刷新失败：${(error as Error).message}`;
  }
}

async function pingRpc(): Promise<void> {
  const response = await rpc.call("health");
  connection.value = rpc.state();
  rpcNote.value = response.error
    ? `RPC 错误 ${response.error.code}: ${response.error.message}`
    : JSON.stringify(response.result);
}

onMounted(() => {
  rpc.connect();
  connection.value = rpc.state();
  void refresh();
});

onBeforeUnmount(() => rpc.close());
</script>

<template>
  <main>
    <header class="topbar">
      <h1>CuteClaw Design Agent</h1>
      <div class="status">
        <span v-if="health">
          Zig host {{ health.version }} · 模型 {{ health.model || "未配置" }} · 会话 {{ health.sessions }} · 工具 {{ health.tools }}
        </span>
        <span :class="['ws', connection]">WebSocket: {{ connection }}</span>
        <button class="ghost" @click="pingRpc">RPC ping</button>
        <button class="ghost" @click="refresh">刷新</button>
      </div>
      <p v-if="rpcNote" class="note">{{ rpcNote }}</p>
    </header>

    <div class="grid">
      <ChatPanel :entries="entries" :busy="busy" :session="session" @send="send" />
      <div class="side">
        <ValidationPanel :report="report" :busy="busy" @run="runDrc" />
        <ToolPanel :tools="tools" />
        <PluginPanel :plugins="plugins" />
        <MetricsPanel :metrics="metrics" />
      </div>
    </div>
  </main>
</template>

<style scoped>
.topbar {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 16px;
}
.topbar h1 {
  margin: 0;
  font-size: 18px;
}
.status {
  display: flex;
  gap: 12px;
  align-items: center;
  font-size: 13px;
  color: var(--muted);
}
.ws.open {
  color: var(--ok);
}
.ws.connecting {
  color: var(--warn);
}
.note {
  flex-basis: 100%;
  margin: 0;
  color: var(--muted);
  font-size: 12px;
}
button.ghost {
  padding: 6px 12px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: transparent;
  color: var(--text);
  cursor: pointer;
}
.grid {
  display: grid;
  grid-template-columns: minmax(320px, 1.4fr) minmax(280px, 1fr);
  gap: 16px;
}
.panel {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  margin-bottom: 16px;
}
.panel header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px;
  border-bottom: 1px solid var(--line);
}
.panel h2 {
  margin: 0;
  font-size: 14px;
}
.count {
  color: var(--muted);
  font-size: 12px;
}
.session {
  color: var(--muted);
  font-size: 12px;
}
.side {
  display: flex;
  flex-direction: column;
}
@media (max-width: 900px) {
  .grid {
    grid-template-columns: 1fr;
  }
}
</style>
