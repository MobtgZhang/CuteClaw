// DeepSeek Harness（Cordis）兼容插件：参数化模型的可复现性检查。
// 模型必须由脚本重跑复现：重跑后测不到的尺寸不是发现，超差的尺寸必须报为问题。

export const name = 'parametric-model-rebuild';
export const inject = ['tools', 'effect'];

function round(value, digits = 4) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'parametric-rebuild' });

  ctx.tools.register({
    name: 'rebuild',
    description: '把重跑脚本后测到的尺寸与目标尺寸逐项对照：测不到、推断、超差、缺失特征都算问题',
    schema: {
      type: 'object',
      properties: {
        targets: { type: 'array' },
        rebuilt: { type: 'array' },
        features: { type: 'array' },
      },
    },
    handler: async (args) => {
      const targets = Array.isArray(args.targets) ? args.targets : [];
      const rebuilt = Array.isArray(args.rebuilt) ? args.rebuilt : [];
      const features = Array.isArray(args.features) ? args.features : [];

      if (targets.length === 0 || rebuilt.length === 0) {
        return {
          content: '缺少目标尺寸或重跑后的实测尺寸：可复现性无法判定',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];
      let maxDrift = 0;

      for (const target of targets) {
        const name = String(target.name ?? '');
        if (!name) {
          findings.push({ kind: 'unnamed_dimension', value: 0, measured: false, severity: 'hard' });
          continue;
        }
        if (!target.measured) {
          findings.push({ kind: 'inferred_target', name, value: Number(target.value_mm ?? 0), measured: false, severity: 'hard' });
          continue;
        }

        const targetValue = Number(target.value_mm ?? 0);
        const tolerance = Number(target.tolerance_mm ?? 0);
        if (!(tolerance > 0)) {
          findings.push({ kind: 'missing_tolerance', name, value: targetValue, measured: true, severity: 'hard' });
          continue;
        }

        const measured = rebuilt.find((entry) => String(entry.name ?? '') === name);
        if (!measured) {
          // 重跑后测不到：这条参数在模型上不可测量，不能当作已满足。
          findings.push({ kind: 'unmeasurable_param', name, value: targetValue, measured: false, severity: 'hard' });
          continue;
        }
        if (!measured.measured) {
          findings.push({ kind: 'inferred_rebuild', name, value: Number(measured.value_mm ?? 0), measured: false, severity: 'hard' });
          continue;
        }

        const drift = Math.abs(Number(measured.value_mm ?? 0) - targetValue);
        if (drift > tolerance) {
          maxDrift = Math.max(maxDrift, drift);
          findings.push({ kind: 'dimension_drift', name, value: round(drift), limit: round(tolerance), measured: true, severity: 'hard' });
        }
      }

      // 特征树必须真的存在于重跑后的模型里：脚本写了但没生成，就是不可复现。
      for (const feature of features) {
        if (!feature.present) {
          findings.push({ kind: 'feature_missing', name: String(feature.name ?? ''), value: 0, measured: true, severity: 'hard' });
        }
      }

      return {
        content: `重跑后对照 ${targets.length} 项目标尺寸：最大超差 ${round(maxDrift)} mm；问题 ${findings.length}`,
        meta: {
          targets: targets.length,
          measured_on_rebuild: rebuilt.filter((entry) => entry.measured).length,
          max_drift_mm: round(maxDrift),
          reproducible: findings.length === 0,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
