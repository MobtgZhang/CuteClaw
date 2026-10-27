// DeepSeek Harness（Cordis）兼容插件：仿真证据门。
// 数值必须来自可复现的求解运行：没有网格与边界条件记录，就没有验证。

export const name = 'fea-simulation-evidence';
export const inject = ['tools', 'effect'];

function round(value, digits = 3) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'simulation-evidence' });

  ctx.tools.register({
    name: 'simulate',
    description: '核对仿真证据：网格与边界条件必须记录，结果必须来自求解器且收敛；凭印象的应力或温度判失败',
    schema: {
      type: 'object',
      properties: {
        mesh: { type: 'object' },
        boundary: { type: 'object' },
        material: { type: 'object' },
        results: { type: 'array' },
      },
    },
    handler: async (args) => {
      const mesh = args.mesh && typeof args.mesh === 'object' ? args.mesh : {};
      const boundary = args.boundary && typeof args.boundary === 'object' ? args.boundary : {};
      const material = args.material && typeof args.material === 'object' ? args.material : {};
      const results = Array.isArray(args.results) ? args.results : [];

      const findings = [];

      const elements = Number(mesh.elements ?? 0);
      const nodes = Number(mesh.nodes ?? 0);
      if (!mesh.recorded || elements <= 0 || nodes <= 0) {
        findings.push({ kind: 'mesh_not_recorded', value: elements, measured: Boolean(mesh.recorded), severity: 'hard' });
      }

      const loads = Array.isArray(boundary.loads) ? boundary.loads : [];
      if (!boundary.recorded || loads.length === 0) {
        findings.push({ kind: 'boundary_not_recorded', value: loads.length, measured: Boolean(boundary.recorded), severity: 'hard' });
      }

      const yieldMpa = Number(material.yield_mpa ?? 0);
      if (!(yieldMpa > 0)) {
        findings.push({ kind: 'material_not_recorded', value: 0, measured: false, severity: 'hard' });
      }

      let fromSolver = 0;
      for (const result of results) {
        const name = String(result.name ?? '');
        if (!name) {
          findings.push({ kind: 'result_without_name', value: 0, measured: false, severity: 'hard' });
          continue;
        }
        if (!result.measured) {
          findings.push({ kind: 'unmeasured_result', name, value: Number(result.value ?? 0), measured: false, severity: 'hard' });
          continue;
        }
        if (!result.from_solver) {
          findings.push({ kind: 'result_not_from_solver', name, value: Number(result.value ?? 0), measured: true, severity: 'hard' });
          continue;
        }
        fromSolver += 1;

        if (!result.converged) {
          findings.push({ kind: 'not_converged', name, value: Number(result.value ?? 0), measured: true, severity: 'hard' });
          continue;
        }

        // 与解析对照：网格过粗或结果异常必须报出来，而不是只报一个数。
        if (result.analytic !== undefined) {
          const analytic = Number(result.analytic);
          const value = Number(result.value ?? 0);
          if (analytic !== 0 && Math.abs(value - analytic) / Math.abs(analytic) > 0.15) {
            findings.push({ kind: 'analytic_mismatch', name, value: round(value - analytic), measured: true, severity: 'hard' });
          }
        }

        if (yieldMpa > 0 && Number(result.value ?? 0) > yieldMpa) {
          findings.push({ kind: 'over_yield', name, value: round(Number(result.value)), limit: round(yieldMpa), measured: true, severity: 'hard' });
        }
      }

      if (results.length === 0) {
        findings.push({ kind: 'no_results', value: 0, measured: false, severity: 'hard' });
      }

      return {
        content: `网格 ${elements} 单元 / ${nodes} 节点；边界条件 ${loads.length} 项；结果 ${results.length}（来自求解器 ${fromSolver}）；问题 ${findings.length}`,
        meta: {
          mesh_elements: elements,
          mesh_nodes: nodes,
          boundary_loads: loads.length,
          results: results.length,
          from_solver: fromSolver,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
