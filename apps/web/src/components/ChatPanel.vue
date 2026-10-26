<script setup lang="ts">
import { nextTick, ref, watch } from "vue";
import type { ChatEntry } from "../types";

const props = defineProps<{
  entries: ChatEntry[];
  busy: boolean;
  session: string;
}>();

const emit = defineEmits<{ (event: "send", text: string): void }>();

const draft = ref("");
const scroller = ref<HTMLElement | null>(null);

watch(
  () => props.entries.length,
  async () => {
    await nextTick();
    if (scroller.value) scroller.value.scrollTop = scroller.value.scrollHeight;
  },
);

function submit(): void {
  const text = draft.value.trim();
  if (!text || props.busy) return;
  emit("send", text);
  draft.value = "";
}
</script>

<template>
  <section class="panel chat">
    <header>
      <h2>对话</h2>
      <span class="session">session: {{ session }}</span>
    </header>

    <div ref="scroller" class="log">
      <article v-for="entry in entries" :key="entry.id" :class="['entry', entry.role]">
        <div class="meta">
          <strong>{{ entry.role }}</strong>
          <span v-if="entry.tool" class="tool">{{ entry.tool }}</span>
          <span v-if="entry.ok === false" class="bad">失败</span>
          <span v-if="entry.rounds" class="rounds">{{ entry.rounds }} 轮</span>
          <span v-if="entry.tokens" class="tokens">{{ entry.tokens }} tokens</span>
        </div>
        <pre>{{ entry.text }}</pre>
      </article>
      <p v-if="busy" class="typing">Agent 正在思考…</p>
    </div>

    <form class="composer" @submit.prevent="submit">
      <input v-model="draft" :disabled="busy" placeholder="描述你的 PCB / 外壳设计需求" />
      <button type="submit" :disabled="busy || !draft.trim()">发送</button>
    </form>
  </section>
</template>

<style scoped>
.chat {
  display: flex;
  flex-direction: column;
  min-height: 420px;
}
.log {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 12px;
}
.entry {
  border-left: 3px solid var(--accent);
  padding: 8px 10px;
  background: rgba(255, 255, 255, 0.04);
  border-radius: 6px;
}
.entry.user {
  border-left-color: var(--ok);
}
.entry.tool {
  border-left-color: var(--warn);
}
.meta {
  display: flex;
  gap: 8px;
  font-size: 12px;
  color: var(--muted);
  margin-bottom: 6px;
}
.bad {
  color: #ff7a7a;
}
pre {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: inherit;
  line-height: 1.5;
}
.typing {
  color: var(--muted);
  font-size: 12px;
}
.composer {
  display: flex;
  gap: 8px;
  padding: 12px;
  border-top: 1px solid var(--line);
}
.composer input {
  flex: 1;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface);
  color: inherit;
}
.composer button {
  padding: 10px 16px;
  border: 0;
  border-radius: 6px;
  background: var(--accent);
  color: #fff;
  cursor: pointer;
}
.composer button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
</style>
