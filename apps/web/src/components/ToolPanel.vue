<script setup lang="ts">
import type { ToolDef } from "../types";

defineProps<{ tools: ToolDef[] }>();
</script>

<template>
  <section class="panel">
    <header>
      <h2>设计工具</h2>
      <span class="count">{{ tools.length }}</span>
    </header>
    <ul class="list">
      <li v-for="tool in tools" :key="tool.name">
        <code>{{ tool.name }}</code>
        <p>{{ tool.description }}</p>
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
.list code {
  color: var(--accent);
  font-weight: 600;
}
.list p {
  margin: 6px 0 0;
  color: var(--muted);
  font-size: 13px;
}
</style>
