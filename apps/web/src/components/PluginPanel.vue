<script setup lang="ts">
import type { PluginInfo } from "../types";

defineProps<{ plugins: PluginInfo[] }>();
</script>

<template>
  <section class="panel">
    <header>
      <h2>DeepSeek Harness 插件</h2>
      <span class="count">{{ plugins.length }}</span>
    </header>
    <ul class="list">
      <li v-for="plugin in plugins" :key="plugin.id">
        <div class="row">
          <code>{{ plugin.id }}</code>
          <span class="version">{{ plugin.version }}</span>
          <span :class="plugin.enabled ? 'ok' : 'off'">{{ plugin.enabled ? "启用" : "停用" }}</span>
        </div>
        <p class="bundle">{{ plugin.bundle }} · {{ plugin.external ? "外部桥接进程" : "Zig 原生" }}</p>
        <div class="caps">
          <span v-for="cap in plugin.capabilities" :key="cap" class="cap">{{ cap }}</span>
        </div>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.list {
  list-style: none;
  margin: 0;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.list li {
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 10px;
  background: var(--surface);
}
.row {
  display: flex;
  gap: 8px;
  align-items: center;
}
.row code {
  color: var(--accent);
  font-weight: 600;
}
.version,
.bundle {
  color: var(--muted);
  font-size: 12px;
}
.ok {
  color: var(--ok);
  font-size: 12px;
}
.off {
  color: var(--muted);
  font-size: 12px;
}
.bundle {
  margin: 6px 0 0;
}
.caps {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 8px;
}
.cap {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 999px;
  background: rgba(124, 165, 255, 0.15);
  color: var(--accent);
}
</style>
