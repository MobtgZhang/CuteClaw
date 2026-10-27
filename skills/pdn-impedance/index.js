// DeepSeek Harness（Cordis）兼容插件：电源分配网络（目标阻抗 + 载流宽度）。
// 目标阻抗必须由实测去耦网络推导：假设出来的阻抗不算结论。

export const name = 'pdn-impedance';
export const inject = ['tools', 'effect'];

function round(value, digits = 4) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

// IPC-2221（外层）：I = k * dT^0.44 * A^0.724，A 为截面积（mil²）。
function ipc2221WidthMils(current, riseC, copperMils) {
  if (!(current > 0) || !(riseC > 0) || !(copperMils > 0)) return null;
  const areaMils2 = (current / 0.024) ** (1 / 0.724);
  return areaMils2 / copperMils;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'pdn' });

  ctx.tools.register({
    name: 'pdn',
    description: '从实测去耦电容、ESR 与回路电感推导目标阻抗，并按实测电流与温升反推载流宽度',
    schema: {
      type: 'object',
      properties: {
        target_ohm: { type: 'number' },
        frequency_hz: { type: 'number' },
        decoupling: { type: 'object' },
        current_a: { type: 'number' },
        temperature_rise_c: { type: 'number' },
        copper_mils: { type: 'number' },
        trace_width_mm: { type: 'number' },
      },
    },
    handler: async (args) => {
      const target = Number(args.target_ohm ?? 0);
      const freq = Number(args.frequency_hz ?? 0);
      const decoupling = args.decoupling || {};
      const capacitance = Number(decoupling.capacitance_f ?? 0);
      const esr = Number(decoupling.esr_ohm ?? 0);
      const esl_nh = Number(decoupling.esl_nh ?? 0);
      const current = Number(args.current_a ?? 0);
      const rise = Number(args.temperature_rise_c ?? 0);
      const copperMils = Number(args.copper_mils ?? 0);
      const widthMm = Number(args.trace_width_mm ?? 0);

      if (!(target > 0) || !(freq > 0) || !(capacitance > 0)) {
        return {
          content: '缺少可测量的目标阻抗、频率或去耦电容：PDN 结论不成立',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];

      // 自谐振频率之上电容失效：只能靠回路电感，阻抗随频率上升。
      const selfResonance = esl_nh > 0 ? 1 / (2 * Math.PI * Math.sqrt((esl_nh * 1e-9) * capacitance)) : null;
      let pdnOhm = Math.max(esr, 1 / (2 * Math.PI * freq * capacitance));
      if (selfResonance !== null && freq > selfResonance) {
        pdnOhm = 2 * Math.PI * freq * (esl_nh * 1e-9);
        findings.push({ kind: 'capacitor_past_resonance', value: round(selfResonance), measured: true, severity: 'hard' });
      }
      if (pdnOhm > target) {
        findings.push({ kind: 'target_impedance_exceeded', value: round(pdnOhm), measured: true, severity: 'hard' });
      }

      // 载流宽度必须由实测电流与温升反推，不能凭经验给一个数。
      const requiredMils = ipc2221WidthMils(current, rise, copperMils);
      if (requiredMils === null) {
        findings.push({ kind: 'unmeasured_current', value: 0, measured: false, severity: 'hard' });
      } else {
        const requiredMm = requiredMils * 0.0254;
        if (widthMm > 0 && widthMm < requiredMm) {
          findings.push({ kind: 'trace_too_narrow', value: round(requiredMm), measured: true, severity: 'hard' });
        }
      }

      return {
        content: `目标 ${target} Ω @ ${freq} Hz：去耦推导 ${round(pdnOhm)} Ω${selfResonance === null ? '' : `（自谐振 ${round(selfResonance)} Hz）`}；载流 ${current} A @ ${rise} °C 需要 ${requiredMils === null ? '不可推导' : `${round(requiredMils * 0.0254)} mm`}（实际 ${widthMm} mm）；问题 ${findings.length}`,
        meta: {
          target_ohm: target,
          frequency_hz: freq,
          pdn_ohm: round(pdnOhm),
          self_resonance_hz: selfResonance === null ? null : round(selfResonance),
          required_trace_width_mm: requiredMils === null ? null : round(requiredMils * 0.0254),
          actual_trace_width_mm: widthMm,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
