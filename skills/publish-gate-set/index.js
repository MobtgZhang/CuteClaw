// DeepSeek Harness（Cordis）兼容插件：发布前的固定门集合。
// 门集合是固定的：模型不能判定某一项「不适用」而跳过，也不能用声明代替执行。

export const name = 'publish-gate-set';
export const inject = ['tools', 'effect'];

// 固定门集合：交付前必须全部跑过，缺一项就不能发布。
const REQUIRED_GATES = ['secrets_scan', 'adversarial_review', 'test_evidence', 'provenance', 'human_approval'];

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'publish-gate' });

  ctx.tools.register({
    name: 'gates',
    description: '核对固定门集合是否真的跑过：未跑、被豁免、只有声明没有证据都判失败',
    schema: {
      type: 'object',
      properties: {
        required_gates: { type: 'array' },
        run: { type: 'array' },
        exemptions: { type: 'array' },
      },
    },
    handler: async (args) => {
      const required = Array.isArray(args.required_gates) && args.required_gates.length > 0
        ? args.required_gates.map(String)
        : REQUIRED_GATES;
      const run = Array.isArray(args.run) ? args.run : [];
      const exemptions = Array.isArray(args.exemptions) ? args.exemptions.map(String) : [];

      if (required.length === 0) {
        return {
          content: '没有门集合：不能宣布交付就绪',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];
      const ran = new Map();

      for (const item of run) {
        const gate = String(item.gate ?? '');
        if (!gate) {
          findings.push({ kind: 'gate_record_without_name', value: 0, measured: false, severity: 'hard' });
          continue;
        }
        ran.set(gate, item);
      }

      for (const gate of required) {
        const item = ran.get(gate);

        if (exemptions.includes(gate)) {
          // 豁免必须由人给出，不能由被评估的工作自己声明。
          findings.push({ kind: 'gate_exempted', gate, value: 0, measured: true, severity: 'hard' });
          continue;
        }

        if (!item) {
          findings.push({ kind: 'gate_not_run', gate, value: 0, measured: true, severity: 'hard' });
          continue;
        }

        if (!item.measured) {
          findings.push({ kind: 'gate_claimed_not_measured', gate, value: 0, measured: false, severity: 'hard' });
          continue;
        }

        if (!item.passed) {
          findings.push({ kind: 'gate_failed', gate, value: 0, measured: true, severity: 'hard' });
        }
      }

      // 跑过但不在集合里的门不能顶替集合里的门。
      for (const gate of ran.keys()) {
        if (!required.includes(gate)) {
          findings.push({ kind: 'gate_outside_set', gate, value: 0, measured: true, severity: 'soft' });
        }
      }

      const hard = findings.filter((f) => f.severity === 'hard').length;

      return {
        content: `门集合 ${required.length} 项，实际跑过 ${ran.size} 项，豁免 ${exemptions.length} 项；问题 ${findings.length}（硬 ${hard}）`,
        meta: {
          required_gates: required.length,
          gates_run: ran.size,
          exemptions: exemptions.length,
          hard_findings: hard,
          findings,
          passed: hard === 0,
        },
      };
    },
  });
}
