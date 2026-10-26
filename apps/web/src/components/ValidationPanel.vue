<script setup lang="ts">
import { ref } from "vue";
import type { DrcReport, JsonValue } from "../types";

const props = defineProps<{ report: DrcReport | null; busy: boolean }>();
const emit = defineEmits<{ (event: "run", project: JsonValue): void }>();

const project = ref(
  JSON.stringify(
    {
      id: "p1",
      name: "demo",
      constraints: [
        { id: "r1", kind: "trace_width", limit: 0.2, direction: "min", severity: "hard" },
        { id: "r2", kind: "clearance", limit: 0.2, direction: "min", severity: "hard" },
        { id: "r3", kind: "drc_errors", limit: 0, direction: "max", severity: "hard" },
      ],
      board: { name: "b1", width: 20, height: 10, trace_width: 0.15, clearance: 0.3 },
    },
    null,
    2,
  ),
);

function run(): void {
  if (props.busy) return;
  let parsed: JsonValue;
  try {
    parsed = JSON.parse(project.value) as JsonValue;
  } catch {
    return;
  }
  emit("run", parsed);
}
</script>

<template>
  <section class="panel">
    <header>
      <h2>工程验证（DRC）</h2>
      <button class="run" :disabled="busy" @click="run">检查</button>
    </header>

    <textarea v-model="project" rows="10" spellcheck="false"></textarea>

    <div v-if="report" :class="['verdict', report.passed ? 'pass' : 'fail']">
      <strong>{{ report.passed ? "PASS" : "FAIL" }}</strong>
      <span>硬约束 {{ report.hard_count }} · 软约束 {{ report.soft_count }}</span>
    </div>

    <ul v-if="report && report.issues.length" class="issues">
      <li v-for="issue in report.issues" :key="issue.rule + issue.ref">
        <code>{{ issue.rule }}</code>
        <span class="severity">{{ issue.severity }}</span>
        <span class="ref">{{ issue.ref }}</span>
        <span class="value">{{ issue.measured }} / {{ issue.limit }}</span>
        <p>{{ issue.message }}</p>
      </li>
    </ul>
  </section>
</template>

<style scoped>
textarea {
  width: 100%;
  min-height: 140px;
  padding: 10px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface);
  color: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
  resize: vertical;
}
.run {
  padding: 6px 12px;
  border: 0;
  border-radius: 6px;
  background: var(--accent);
  color: #fff;
  cursor: pointer;
}
.run:disabled {
  opacity: 0.5;
}
.verdict {
  margin: 12px 0;
  padding: 10px 12px;
  border-radius: 6px;
  font-size: 13px;
}
.verdict.pass {
  background: rgba(74, 222, 128, 0.12);
  color: var(--ok);
}
.verdict.fail {
  background: rgba(255, 122, 122, 0.12);
  color: #ff7a7a;
}
.issues {
  list-style: none;
  margin: 0;
  padding: 0 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.issues li {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 8px 10px;
  font-size: 12px;
}
.issues code {
  color: var(--accent);
}
.severity {
  color: #ff7a7a;
}
.ref,
.value {
  color: var(--muted);
}
.issues p {
  flex-basis: 100%;
  margin: 0;
  color: var(--muted);
}
</style>
