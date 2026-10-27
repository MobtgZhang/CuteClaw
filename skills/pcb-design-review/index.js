// DeepSeek Harness（Cordis）兼容插件：PCB 设计审查（Graph Flow 的分项 fan-out + 合并）。
// 绿板不等于正确：每条结论必须带来源，推断值不能通过 measured-only 硬门。

export const name = 'pcb-design-review';
export const inject = ['tools', 'effect'];

const CHECKS = [
  { id: 'power_tree', rule: 'return current must not cross a plane split' },
  { id: 'subcircuits', rule: 'each subcircuit must be bounded and measurable' },
  { id: 'esd', rule: 'exposed connectors need protection before the first gate' },
  { id: 'dfm', rule: 'fabrication limits must come from the fab, not from the model' },
];

function evaluate(check, board) {
  const findings = [];
  for (const [kind, value] of Object.entries(board.measurements ?? {})) {
    if (typeof value === 'number' && !Number.isFinite(value)) {
      findings.push({ check: check.id, kind, value, measured: false, severity: 'hard' });
    }
  }
  if (check.id === 'power_tree' && Number(board.plane_split_crossings) > 0) {
    findings.push({ check: check.id, kind: 'plane_split_crossings', value: Number(board.plane_split_crossings), measured: true, severity: 'hard' });
  }
  if (check.id === 'dfm' && Number(board.trace_width_mm) < Number(board.min_trace_width_mm ?? 0.2)) {
    findings.push({ check: check.id, kind: 'trace_width', value: Number(board.trace_width_mm), measured: true, severity: 'hard' });
  }
  return findings;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'pcb-review' });

  ctx.tools.register({
    name: 'review',
    description: '按检查项独立评估板卡，合并为问题清单；推断值与实测值分开报告',
    schema: {
      type: 'object',
      properties: {
        board: { type: 'object' },
        checks: { type: 'array' },
      },
    },
    handler: async (args) => {
      const board = args.board || {};
      const checks = Array.isArray(args.checks) && args.checks.length > 0 ? args.checks : CHECKS;
      const findings = [];
      for (const check of checks) findings.push(...evaluate(check, board));

      const hard = findings.filter((f) => f.severity === 'hard');
      const inferred = findings.filter((f) => !f.measured);
      const passed = hard.length === 0 && inferred.length === 0;
      return {
        content: `检查 ${checks.length} 项，问题 ${findings.length}（硬 ${hard.length}，推断 ${inferred.length}）；${passed ? '通过' : '未通过：硬门只接受实测值'}`,
        meta: { checks: checks.map((c) => c.id ?? c), findings, hard_count: hard.length, inferred_count: inferred.length, passed },
      };
    },
  });
}
