// DeepSeek Harness（Cordis）兼容插件：Graph Flow 工作形状审计。
// 插件只提供能力，不拥有调度权：真正的执行计划仍由 Zig 侧的图执行器决定。

export const name = 'graph-orchestrator';
export const inject = ['tools', 'effect'];

function buildIndex(nodes) {
  const byId = new Map();
  for (const n of nodes) byId.set(n.id, n);
  return byId;
}

// 真实边：源节点写入工件，或下游显式读取 node.<id>。其余的先后顺序只是叙述。
function isRealEdge(byId, from, to) {
  const source = byId.get(from);
  const target = byId.get(to);
  if (!source || !target) return false;
  if (source.writes) return true;
  const payload = JSON.stringify(target.payload ?? '');
  return payload.includes(`node.${source.id}.`);
}

function layers(byId, nodes) {
  const depth = new Map();
  function resolve(id, seen) {
    if (depth.has(id)) return depth.get(id);
    if (seen.has(id)) return 0;
    seen.add(id);
    const node = byId.get(id);
    let d = 0;
    for (const dep of node?.depends_on ?? []) d = Math.max(d, resolve(dep, seen) + 1);
    depth.set(id, d);
    return d;
  }
  for (const n of nodes) resolve(n.id, new Set());
  const groups = new Map();
  for (const n of nodes) {
    const d = depth.get(n.id) ?? 0;
    if (!groups.has(d)) groups.set(d, []);
    groups.get(d).push(n.id);
  }
  return [...groups.entries()].sort((a, b) => a[0] - b[0]).map(([, ids]) => ids);
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'graph-flow' });

  ctx.tools.register({
    name: 'audit',
    description: '审计依赖图：真实边 / 叙述边 / 可并行层，并给出是否值得 fan-out 的建议',
    schema: {
      type: 'object',
      properties: { nodes: { type: 'array' } },
    },
    handler: async (args) => {
      const nodes = Array.isArray(args.nodes) ? args.nodes : [];
      const byId = buildIndex(nodes);
      const real = [];
      const narration = [];
      for (const n of nodes) {
        for (const dep of n.depends_on ?? []) {
          if (isRealEdge(byId, dep, n.id)) real.push({ from: dep, to: n.id });
          else narration.push({ from: dep, to: n.id, reason: 'no artifact written by the source' });
        }
      }
      const grouped = layers(byId, nodes);
      const splittable = grouped.filter((ids) => ids.length > 1);
      const recommendation = nodes.length < 2
        ? 'single node: a graph adds nothing, keep it a single call'
        : splittable.length > 0
          ? `work splits: fan out ${splittable.reduce((s, ids) => s + ids.length, 0)} nodes across ${splittable.length} layers, then consolidate in layers`
          : 'sequential work: keep it a chain, fan-out would only add coordination cost';
      return {
        content: `节点 ${nodes.length}，真实边 ${real.length}，叙述边 ${narration.length}，层 ${grouped.length}`,
        meta: { real_edges: real, narration_edges: narration, layers: grouped, recommendation },
      };
    },
  });
}
