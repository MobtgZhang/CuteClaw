// DeepSeek Harness（Cordis）兼容插件：刀模分层检查与材料利用率。
// 合并成一层就无法模切：Cut / Crease / Perforation 必须是三个独立图层。

export const name = 'dieline-export';
export const inject = ['tools', 'effect'];

const REQUIRED = ['cut', 'crease', 'perforation'];

function round(value) {
  return Math.round(value * 100) / 100;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'dieline-export' });

  ctx.tools.register({
    name: 'layers',
    description: '检查刀模图层是否按 Cut / Crease / Perforation 分开，并计算材料利用率与出血',
    schema: {
      type: "object",
      properties: {
        layers: { type: "array", items: { type: "object" } },
        sheet: { type: "object" },
        bleed_mm: { type: "number" },
      },
    },
    handler: async (args) => {
      const layers = Array.isArray(args.layers) ? args.layers : [];
      const sheet = args.sheet || {};
      const sheetArea = Number(sheet.area_mm2 ?? 0);
      const bleed = Number(args.bleed_mm ?? 3);

      if (!(sheetArea > 0)) {
        return { content: '缺少可测量的板材面积：利用率不是结论', meta: { error: 'unmeasured_input' } };
      }

      const byName = new Map();
      for (const layer of layers) {
        const name = String(layer?.name ?? '').toLowerCase();
        byName.set(name, Number(layer?.entities ?? 0));
      }

      const findings = [];
      for (const required of REQUIRED) {
        if (!byName.has(required)) findings.push({ kind: 'missing_layer', value: 0, ref: required, severity: 'hard' });
      }
      for (const layer of layers) {
        const name = String(layer?.name ?? '').toLowerCase();
        if (REQUIRED.filter((r) => name.includes(r)).length > 1) {
          findings.push({ kind: 'merged_layer', value: Number(layer?.entities ?? 0), ref: name, severity: 'hard' });
        }
      }

      const dielineArea = layers.reduce((sum, layer) => sum + Number(layer?.area_mm2 ?? 0), 0);
      const utilization = dielineArea > 0 ? round((dielineArea / sheetArea) * 100) : 0;

      return {
        content: `刀模图层 ${byName.size}：${REQUIRED.join(' / ')}；利用率 ${utilization}%，出血 ${bleed} mm；问题 ${findings.length}；${findings.length ? '未通过' : '通过'}`,
        meta: {
          layers: Object.fromEntries(byName),
          required_layers: REQUIRED,
          utilization_percent: utilization,
          bleed_mm: bleed,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
