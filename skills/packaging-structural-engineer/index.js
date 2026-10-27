// DeepSeek Harness（Cordis）兼容插件：包装结构工程（参数化展开图 + 刀模分层）。
// 尺寸必须可测量：算不出来的数字不算结论。

export const name = 'packaging-structural-engineer';
export const inject = ['tools', 'effect'];

// FEFCO 常用箱型：blank 展开尺寸由内尺寸与材料厚度推导。
const PATTERNS = {
  '0201': { name: 'regular slotted container', blankHeight: (d) => d.H + d.W, blankWidth: (d) => 2 * (d.L + d.W) + d.glue },
  '0301': { name: 'telescopic lid', blankHeight: (d) => d.H + d.W, blankWidth: (d) => 2 * (d.L + d.W) + d.glue },
  '0713': { name: 'folder with hinged lid', blankHeight: (d) => d.H + 2 * d.W, blankWidth: (d) => d.L + 2 * d.W + d.glue },
};

function round(value) {
  return Math.round(value * 100) / 100;
}

function creaseLines(d, pattern, blankWidth, blankHeight) {
  const lines = [];
  const panels = pattern.id === '0713' ? [d.W, d.L, d.W, d.glue] : [d.L, d.W, d.L, d.W, d.glue];
  let x = 0;
  for (let i = 0; i < panels.length - 1; i += 1) {
    x += panels[i];
    lines.push({ x: round(x), from: 0, to: blankHeight });
  }
  // 折线：上下摇盖各为半高（0713 的摇盖为全高，只有底部一条）
  const bottom = pattern.id === '0713' ? d.W : d.W / 2;
  lines.push({ y: round(bottom), from: 0, to: blankWidth });
  if (pattern.id !== '0713') lines.push({ y: round(blankHeight - bottom), from: 0, to: blankWidth });
  return lines;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'packaging-structure' });

  ctx.tools.register({
    name: 'dieline',
    description: '按 FEFCO 箱型与内尺寸生成展开图：Cut / Crease / Perforation 分层、面积与材料利用率（利用率 = 实际展开面积 / 板材面积）',
    schema: {
      type: 'object',
      properties: {
        fefco: { type: 'string' },
        inner: { type: 'object' },
        caliper_mm: { type: 'number' },
        perforation: { type: 'array' },
        sheet: { type: 'object' },
      },
    },
    handler: async (args) => {
      const pattern = PATTERNS[args.fefco ?? '0201'];
      if (!pattern) return { content: `未知 FEFCO 箱型 ${args.fefco}`, meta: { error: 'unknown_pattern' } };

      const inner = args.inner || {};
      const caliper = Number(args.caliper_mm ?? 0);
      const glue = Number(args.glue_mm ?? 50);
      // 刀模尺寸 = 内尺寸 + 材料厚度补偿（折叠处需要让料）
      const d = {
        L: Number(inner.L ?? 0) + 2 * caliper,
        W: Number(inner.W ?? 0) + 2 * caliper,
        H: Number(inner.H ?? 0) + caliper,
        glue,
      };
      const blankWidth = round(pattern.blankWidth(d));
      const blankHeight = round(pattern.blankHeight(d));
      const patternArea = round(blankWidth * blankHeight);
      const area = round(patternArea / 1000000);
      // 内容积单位是升（mm³ / 1e6），不能和面积（m²）相除，否则利用率是个无意义的数字。
      const innerVolumeL = round((d.L * d.W * d.H) / 1000000);
      const sheet = args.sheet || {};
      const sheetArea = round(Number(sheet.area_mm2 ?? (Number(sheet.length_mm) * Number(sheet.width_mm) || 0)));
      // 材料利用率 = 实际展开面积 / 板材面积：没有板材面积就算不出来，不能编数字。
      const utilization = sheetArea > 0 ? round((patternArea / sheetArea) * 100) : null;

      const findings = [];
      if (sheetArea <= 0) findings.push({ kind: 'unmeasured_utilization', field: 'sheet_area_mm2', value: 0, measured: false, severity: 'hard' });

      const layers = {
        cut: [{ type: 'rectangle', width: blankWidth, height: blankHeight }],
        crease: creaseLines(d, pattern, blankWidth, blankHeight),
        perforation: Array.isArray(args.perforation) ? args.perforation : [],
      };

      return {
        content: `FEFCO ${args.fefco ?? '0201'} ${pattern.name}：展开 ${blankWidth} x ${blankHeight} mm，面积 ${area} m²，内容积 ${innerVolumeL} L，材料利用率 ${utilization === null ? '未测量' : `${utilization}%`}；问题 ${findings.length}；${findings.length ? '未通过' : '通过'}`,
        meta: {
          fefco: args.fefco ?? '0201',
          pattern: pattern.name,
          blank: { width: blankWidth, height: blankHeight },
          layers,
          pattern_area_mm2: patternArea,
          sheet_area_mm2: sheetArea,
          inner_volume_l: innerVolumeL,
          utilization,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
