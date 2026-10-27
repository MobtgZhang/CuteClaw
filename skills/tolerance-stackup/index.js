// DeepSeek Harness（Cordis）兼容插件：公差链（最坏情况 + RSS）。
// 只按名义值算的公差链不算结论：每个贡献都必须来自实测尺寸。

export const name = 'tolerance-stackup';
export const inject = ['tools', 'effect'];

function round(value) {
  return Math.round(value * 1000) / 1000;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'tolerance-stackup' });

  ctx.tools.register({
    name: 'stackup',
    description: '累加公差链：最坏情况必须满足目标配合，RSS 只作为参考；推断贡献不计入',
    schema: {
      type: "object",
      properties: {
        target_mm: { type: "number" },
        contributions: { type: "array", items: { type: "object" } },
      },
    },
    handler: async (args) => {
      const target = Number(args.target_mm ?? 0);
      const rows = Array.isArray(args.contributions) ? args.contributions : [];
      const measured = rows.filter((r) => r && r.measured !== false && Number.isFinite(Number(r.value_mm)));
      const inferred = rows.length - measured.length;

      if (measured.length === 0) {
        return { content: '没有可测量的公差贡献：公差链不是结论', meta: { error: 'unmeasured_input', inferred } };
      }

      const worst = measured.reduce((sum, r) => sum + Number(r.value_mm), 0);
      const rss = Math.sqrt(measured.reduce((sum, r) => sum + Number(r.value_mm) ** 2, 0));
      const passed = target > 0 ? worst <= target : worst === 0;

      return {
        content: `公差链：最坏情况 ${round(worst)} mm，RSS ${round(rss)} mm，目标 ${target} mm；${passed ? '通过' : '未通过'}（推断贡献 ${inferred} 不计入）`,
        meta: {
          target_mm: target,
          worst_case_mm: round(worst),
          rss_mm: round(rss),
          contributions: measured.map((r) => ({ name: r.name ?? 'unnamed', value_mm: Number(r.value_mm) })),
          inferred,
          passed,
        },
      };
    },
  });
}
