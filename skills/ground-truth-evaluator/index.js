// DeepSeek Harness（Cordis）兼容插件：自进化的评估门。
// 进步必须由冻结的未见测试集证明：评估者不能是生成者自己，跑不过不能改测试集。

export const name = 'ground-truth-evaluator';
export const inject = ['tools', 'effect'];

function round(value, digits = 3) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'ground-truth' });

  ctx.tools.register({
    name: 'evaluate',
    description: '用冻结的未见测试集评估：评估者必须独立于生成者，测试集不可因为跑不过而被改写',
    schema: {
      type: 'object',
      properties: {
        eval_set: { type: 'array' },
        generator: { type: 'string' },
        evaluator: { type: 'string' },
        frozen: { type: 'boolean' },
      },
    },
    handler: async (args) => {
      const evalSet = Array.isArray(args.eval_set) ? args.eval_set : [];
      const generator = String(args.generator ?? '');
      const evaluator = String(args.evaluator ?? '');
      const frozen = Boolean(args.frozen);

      if (evalSet.length === 0) {
        return {
          content: '没有评估集：自进化不能凭印象判定进步',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];

      // 测试集必须冻结：为了通过而改写测试集，等于把判断权交回给被评估的一方。
      if (!frozen) {
        findings.push({ kind: 'eval_set_not_frozen', value: 0, measured: false, severity: 'hard' });
      }
      // 评估者必须与生成者隔离：同一个模型既生成又打分不构成独立证据。
      if (!evaluator || evaluator === generator) {
        findings.push({ kind: 'evaluator_is_generator', value: 0, measured: true, severity: 'hard' });
      }

      let unseen = 0;
      let measured = 0;

      for (const task of evalSet) {
        const id = String(task.id ?? '');
        if (!id) {
          findings.push({ kind: 'task_without_id', value: 0, measured: false, severity: 'hard' });
          continue;
        }

        if (task.unseen) {
          unseen += 1;
        } else {
          findings.push({ kind: 'seen_task_in_set', task: id, value: 0, measured: true, severity: 'hard' });
        }

        if (!task.measured) {
          findings.push({ kind: 'unmeasured_result', task: id, value: 0, measured: false, severity: 'hard' });
          continue;
        }
        measured += 1;

        if (task.baseline !== undefined && task.score !== undefined && Number(task.score) < Number(task.baseline)) {
          findings.push({ kind: 'regression', task: id, value: round(Number(task.score) - Number(task.baseline)), measured: true, severity: 'hard' });
        }
      }

      if (measured === 0) {
        findings.push({ kind: 'no_measured_result', value: 0, measured: false, severity: 'hard' });
      }

      const passRate = measured > 0 ? measured / evalSet.length : 0;

      return {
        content: `评估集 ${evalSet.length} 条（未见 ${unseen}、可测量 ${measured}）；评估者 ${evaluator || '未指定'}；问题 ${findings.length}`,
        meta: {
          tasks: evalSet.length,
          unseen,
          measured,
          pass_rate: round(passRate),
          frozen,
          independent_evaluator: Boolean(evaluator) && evaluator !== generator,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
