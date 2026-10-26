<script setup lang="ts">
import type { Metrics } from "../types";

defineProps<{ metrics: Metrics }>();
</script>

<template>
  <section class="panel">
    <header>
      <h2>进化指标</h2>
      <span class="count">{{ metrics.skills.length }}</span>
    </header>
    <table>
      <thead>
        <tr>
          <th>技能</th>
          <th>调用</th>
          <th>成功</th>
          <th>失败</th>
          <th>成功率</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in metrics.skills" :key="row.skill">
          <td>{{ row.skill }}</td>
          <td>{{ row.invocations }}</td>
          <td>{{ row.successes }}</td>
          <td>{{ row.failures }}</td>
          <td>{{ (row.success_rate * 100).toFixed(1) }}%</td>
        </tr>
        <tr v-if="metrics.skills.length === 0">
          <td colspan="5" class="empty">暂无数据</td>
        </tr>
      </tbody>
    </table>
  </section>
</template>

<style scoped>
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
th,
td {
  text-align: left;
  padding: 8px 12px;
  border-bottom: 1px solid var(--line);
}
th {
  color: var(--muted);
  font-weight: 500;
}
.empty {
  color: var(--muted);
}
</style>
