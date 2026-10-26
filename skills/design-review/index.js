// DeepSeek Harness（Cordis）兼容插件：设计评审技能。

export const name = 'design-review';
export const inject = ['tools', 'effect'];

const HARD_KINDS = new Set(['drc_errors', 'clearance', 'mounting_holes']);

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'review' });

  ctx.tools.register({
    name: 'review',
    description: '先淘汰硬约束违规候选，再按代价排序，输出胜出方案与理由',
    schema: {
      type: 'object',
      properties: {
        candidates: { type: 'array' },
        limits: { type: 'object' },
      },
    },
    handler: async (args) => {
      const candidates = Array.isArray(args.candidates) ? args.candidates : [];
      const limits = args.limits || {};
      const survivors = [];
      const eliminated = [];
      for (const c of candidates) {
        const m = c.measurements || {};
        let bad = false;
        for (const kind of HARD_KINDS) {
          if (kind in limits && Number(m[kind]) > Number(limits[kind])) bad = true;
        }
        if (bad) eliminated.push(c.id);
        else survivors.push({ id: c.id, cost: Number(m.rat_length_mm) ?? 0 });
      }
      survivors.sort((a, b) => a.cost - b.cost);
      const winner = survivors[0] || null;
      return {
        content: winner ? `胜出 ${winner.id}（代价 ${winner.cost}），淘汰 ${eliminated.join(',') || '无'}` : '没有合格候选',
        meta: { winner, survivors, eliminated },
      };
    },
  });
}
