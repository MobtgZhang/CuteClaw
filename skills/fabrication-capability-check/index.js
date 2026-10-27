// DeepSeek Harness（Cordis）兼容插件：设计规则与工厂公布能力逐项对照。
// 对照不上的规则不算通过：它只是未验证，不能因为没报错就宣布可制造。

export const name = 'fabrication-capability-check';
export const inject = ['tools', 'effect'];

function round(value) {
  return Math.round(value * 1000) / 1000;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'fabrication-capability' });

  ctx.tools.register({
    name: 'compare',
    description: '把设计规则与工厂公布能力逐项对照：超出能力、缺少能力条目、推断值都算问题',
    schema: {
      type: 'object',
      properties: {
        rules: { type: 'array' },
        capability: { type: 'array' },
      },
    },
    handler: async (args) => {
      const rules = Array.isArray(args.rules) ? args.rules : [];
      const capability = Array.isArray(args.capability) ? args.capability : [];

      if (rules.length === 0 || capability.length === 0) {
        return {
          content: '缺少可对照的设计规则或工厂能力：不能宣布可制造',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];
      for (const rule of rules) {
        const kind = String(rule.kind ?? '');
        const value = Number(rule.value_mm ?? 0);
        const line = capability.find((entry) => entry.kind === kind);

        if (!line) {
          findings.push({ kind: 'unmatched_rule', rule: kind, value: 0, measured: true, severity: 'hard' });
          continue;
        }
        if (!rule.measured) {
          findings.push({ kind: 'unmeasured_rule', rule: kind, value: 0, measured: false, severity: 'hard' });
          continue;
        }
        const limit = Number(line.limit_mm ?? 0);
        if (value < limit) {
          findings.push({ kind: 'beyond_capability', rule: kind, value: round(value), limit: round(limit), measured: true, severity: 'hard' });
        }
      }

      return {
        content: `规则 ${rules.length} 条，工厂能力 ${capability.length} 条；问题 ${findings.length}（未对照 ${findings.filter((f) => f.kind === 'unmatched_rule').length}，推断 ${findings.filter((f) => f.kind === 'unmeasured_rule').length}，超出能力 ${findings.filter((f) => f.kind === 'beyond_capability').length}）`,
        meta: {
          rules: rules.length,
          capability_lines: capability.length,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
