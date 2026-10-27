// DeepSeek Harness（Cordis）兼容插件：可求值的分支路由。
// 路由必须由谓词对执行状态求值决定：用措辞或叙述顺序决定分支不算路由。

export const name = 'predicate-router';
export const inject = ['tools', 'effect'];

const OPS = ['>', '>=', '<', '<=', '==', '!='];

function evaluate(op, actual, threshold) {
  switch (op) {
    case '>': return actual > threshold;
    case '>=': return actual >= threshold;
    case '<': return actual < threshold;
    case '<=': return actual <= threshold;
    case '==': return actual === threshold;
    case '!=': return actual !== threshold;
    default: return null;
  }
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'predicate-route' });

  ctx.tools.register({
    name: 'route',
    description: '对执行状态求值选择分支：谓词必须是字段+运算符+阈值，求值失败必须回退默认分支并记录',
    schema: {
      type: 'object',
      properties: {
        predicate: { type: 'object' },
        state: { type: 'object' },
        default_branch: { type: 'string' },
        branches: { type: 'array' },
      },
    },
    handler: async (args) => {
      const predicate = args.predicate && typeof args.predicate === 'object' ? args.predicate : {};
      const state = args.state && typeof args.state === 'object' ? args.state : {};
      const defaultBranch = String(args.default_branch ?? '');
      const branches = Array.isArray(args.branches) ? args.branches.map(String) : [];

      const findings = [];

      // 谓词必须是可求值的声明式规则：自然语言措辞不能决定跑哪条分支。
      if (predicate.prose) {
        findings.push({ kind: 'prose_predicate', value: 0, measured: false, severity: 'hard' });
      }

      if (!defaultBranch) {
        findings.push({ kind: 'no_default_branch', value: 0, measured: false, severity: 'hard' });
      }

      let chosen = defaultBranch;
      let usedDefault = true;

      if (!predicate.prose) {
        const field = String(predicate.field ?? '');
        const op = String(predicate.op ?? '');

        if (!field || !OPS.includes(op)) {
          findings.push({ kind: 'invalid_predicate', field, op, value: 0, measured: false, severity: 'hard' });
        } else if (!(field in state)) {
          // 状态里没有这个字段：不能凭记忆补一个值，必须回退默认分支。
          findings.push({ kind: 'missing_field', field, value: 0, measured: false, severity: 'hard' });
        } else {
          const actual = state[field];
          if (typeof actual !== 'number') {
            findings.push({ kind: 'non_numeric_state', field, value: 0, measured: true, severity: 'hard' });
          } else {
            const result = evaluate(op, actual, Number(predicate.threshold));
            if (result === null) {
              findings.push({ kind: 'predicate_not_evaluable', field, op, value: 0, measured: false, severity: 'hard' });
            } else {
              chosen = result ? String(predicate.true_branch ?? defaultBranch) : String(predicate.false_branch ?? defaultBranch);
              usedDefault = chosen === defaultBranch;
              if (!usedDefault && !branches.includes(chosen)) {
                findings.push({ kind: 'branch_not_in_set', branch: chosen, value: 0, measured: true, severity: 'hard' });
              }
            }
          }
        }
      } else {
        findings.push({ kind: 'routed_from_prose', branch: chosen, value: 0, measured: true, severity: 'hard' });
      }

      const hard = findings.filter((f) => f.severity === 'hard').length;

      return {
        content: `路由 ${chosen}（默认分支 ${defaultBranch || '未定义'}${usedDefault ? '，走了默认' : ''}）；问题 ${findings.length}（硬 ${hard}）`,
        meta: {
          predicate_type: predicate.prose ? 'prose' : 'declarative',
          chosen_branch: chosen,
          used_default: usedDefault,
          hard_findings: hard,
          findings,
          passed: hard === 0,
        },
      };
    },
  });
}
