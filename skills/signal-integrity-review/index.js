// DeepSeek Harness（Cordis）兼容插件：信号完整性（阻抗 + 回流路径）。
// 阻抗必须由叠层与实测几何推导：假设出来的叠层不算结论。

export const name = 'signal-integrity-review';
export const inject = ['tools', 'effect'];

function round(value) {
  return Math.round(value * 100) / 100;
}

// Hamden 近似（微带）：线宽与介质厚度之比决定用哪一段公式。
function microstripOhms(width, height, er) {
  const ratio = width / height;
  if (ratio < 1) return (87 / Math.sqrt(er + 2)) * Math.log(4 / ratio + 0.8 * ratio);
  return (116 / Math.sqrt(er + 2)) * Math.log(1.256 / ratio + 0.693);
}

// 带状线近似只在 w/h < 0.35 时成立；超出范围就报告不可推导，而不是编一个数。
function striplineOhms(width, height, er) {
  const ratio = width / height;
  if (ratio >= 0.35) return null;
  return (60 / Math.sqrt(er)) * Math.log(4 / ratio);
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'signal-integrity' });

  ctx.tools.register({
    name: 'impedance',
    description: '从叠层与实测线宽推导阻抗，并检查回流路径是否被参考平面分割打断',
    schema: {
      type: 'object',
      properties: {
        stackup: { type: 'object' },
        geometry: { type: 'object' },
        target_ohm: { type: 'number' },
        plane_split: { type: 'boolean' },
      },
    },
    handler: async (args) => {
      const stackup = args.stackup || {};
      const geometry = args.geometry || {};
      const er = Number(stackup.er ?? 0);
      const height = Number(stackup.dielectric_mm ?? 0);
      const width = Number(geometry.trace_width_mm ?? 0);

      if (!(er > 0) || !(height > 0) || !(width > 0)) {
        return { content: '缺少可测量的叠层或几何：阻抗不是结论', meta: { error: 'unmeasured_input' } };
      }

      const mode = stackup.type === 'stripline' ? 'stripline' : 'microstrip';
      const ohms = mode === 'stripline' ? striplineOhms(width, height, er) : microstripOhms(width, height, er);
      const target = Number(args.target_ohm ?? 50);
      const split = Boolean(args.plane_split);

      if (ohms === null) {
        return {
          content: `${mode} 近似只在 w/h < 0.35 时成立（当前 w/h ${round(width / height)}）：阻抗不可推导，不算结论`,
          meta: { mode, impedance_ohm: null, out_of_range: true, findings: [], passed: false },
        };
      }

      const deviation = target > 0 ? round(((ohms - target) / target) * 100) : 0;
      const findings = [];
      if (Math.abs(deviation) > 10) findings.push({ kind: 'impedance_mismatch', value: deviation, measured: true, severity: 'hard' });
      if (split) findings.push({ kind: 'return_path_split', value: 1, measured: true, severity: 'hard' });

      return {
        content: `${mode} ${round(ohms)} Ω（er ${er}，介质 ${height} mm，线宽 ${width} mm）；目标 ${target} Ω 偏差 ${deviation}%；回流路径${split ? '被分割' : '连续'}；问题 ${findings.length}`,
        meta: {
          mode,
          impedance_ohm: round(ohms),
          target_ohm: target,
          deviation_percent: deviation,
          return_path_split: split,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
