// DeepSeek Harness（Cordis）兼容插件：PCB 布局技能。
// 由 Zig 桥接进程调用；插件本身不拥有调度权。

export const name = 'pcb-layout';
export const inject = ['tools', 'effect'];

function cluster(components) {
  const groups = new Map();
  for (const c of components) {
    const key = c.group || c.ref || 'ungrouped';
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(c);
  }
  return [...groups.entries()].map(([key, items]) => ({ key, count: items.length }));
}

function ratLength(components) {
  let total = 0;
  for (const c of components) {
    const x = Number(c.x) || 0;
    const y = Number(c.y) || 0;
    total += Math.hypot(x, y);
  }
  return Math.round(total * 100) / 100;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'pcb-layout' });

  ctx.tools.register({
    name: 'analyze',
    description: '分析器件聚类与关键连接器优先级，返回布局建议',
    schema: {
      type: 'object',
      properties: { components: { type: 'array' }, critical_refs: { type: 'array' } },
    },
    handler: async (args) => {
      const components = Array.isArray(args.components) ? args.components : [];
      const critical = Array.isArray(args.critical_refs) ? args.critical_refs : [];
      const suggestions = [];
      for (const ref of critical) suggestions.push({ ref, action: 'anchor_first' });
      for (const g of cluster(components)) suggestions.push({ ref: g.key, action: 'cluster', count: g.count });
      return {
        content: `聚类 ${cluster(components).length} 组，飞线代价 ${ratLength(components)} mm`,
        meta: { clusters: cluster(components), rat_length_mm: ratLength(components), suggestions },
      };
    },
  });
}
