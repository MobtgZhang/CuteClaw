// DeepSeek Harness（Cordis）兼容插件：包装循环经济性评分。
// 分数必须由实际材料成分与装载质量推导：没有材料清单就没有评分，猜测不算发现。

export const name = 'eco-packaging-score';
export const inject = ['tools', 'effect'];

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

// 评分权重：可回收性 60、再生含量 25、材料单一化 15。
const WEIGHTS = { recyclability: 60, recycled_content: 25, mono_material: 15 };

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'eco-packaging' });

  ctx.tools.register({
    name: 'score',
    description: '按实际材料成分与装载质量计算循环经济性评分：推断的材料属性不计入，复合材质判为不可回收',
    schema: {
      type: 'object',
      properties: {
        materials: { type: 'array' },
        product_mass_g: { type: 'number' },
        threshold: { type: 'number' },
      },
    },
    handler: async (args) => {
      const materials = Array.isArray(args.materials) ? args.materials : [];
      const productMass = Number(args.product_mass_g ?? 0);
      const threshold = Number(args.threshold ?? 70);

      if (materials.length === 0 || !(productMass > 0)) {
        return {
          content: '缺少可核对的材料清单或装载质量：评分不成立',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];
      let totalMass = 0;
      let measuredMass = 0;
      let recyclableWeighted = 0;
      let recycledWeighted = 0;
      let monoMass = 0;

      for (const material of materials) {
        const mass = Number(material.mass_g ?? 0);
        if (!(mass > 0)) {
          findings.push({ kind: 'unmeasured_mass', material: String(material.name ?? ''), value: 0, measured: false, severity: 'hard' });
          continue;
        }
        totalMass += mass;

        if (!material.measured) {
          findings.push({ kind: 'unmeasured_material', material: String(material.name ?? ''), value: mass, measured: false, severity: 'hard' });
          continue;
        }
        measuredMass += mass;

        // 复合材质（层压、异质粘接）在回收流里按不可回收处理：这是实际分拣结果，不是印象分。
        const composite = Boolean(material.composite);
        const recyclable = composite ? 0 : Number(material.recyclable_rate ?? 0);
        if (composite) {
          findings.push({ kind: 'composite_material', material: String(material.name ?? ''), value: mass, measured: true, severity: 'hard' });
        }
        if (!composite && !(recyclable > 0)) {
          findings.push({ kind: 'not_recyclable', material: String(material.name ?? ''), value: mass, measured: true, severity: 'hard' });
        }

        recyclableWeighted += recyclable * mass;
        recycledWeighted += Number(material.recycled_content ?? 0) * mass;
        if (!composite) monoMass += mass;
      }

      if (totalMass === 0) {
        return {
          content: '材料清单里没有可测量的质量：评分不成立',
          meta: { error: 'unmeasured_input', findings, passed: false },
        };
      }

      const recyclabilityScore = (recyclableWeighted / totalMass) * WEIGHTS.recyclability;
      const recycledScore = (recycledWeighted / totalMass) * WEIGHTS.recycled_content;
      const monoScore = (monoMass / totalMass) * WEIGHTS.mono_material;
      const score = recyclabilityScore + recycledScore + monoScore;

      // 包装相对产品的质量占比：减材料必须按实际装载质量算，不能按面积猜。
      const massRatio = totalMass / productMass;
      if (massRatio > 1) {
        findings.push({ kind: 'packaging_heavier_than_product', value: round(massRatio), measured: true, severity: 'hard' });
      }
      if (score < threshold) {
        findings.push({ kind: 'score_below_threshold', value: round(score), measured: true, severity: 'hard' });
      }

      return {
        content: `循环经济性评分 ${round(score)} / 100（可回收 ${round(recyclabilityScore)} + 再生 ${round(recycledScore)} + 单一材料 ${round(monoScore)}）；包装/产品质量比 ${round(massRatio)}；问题 ${findings.length}`,
        meta: {
          score: round(score),
          threshold,
          total_mass_g: round(totalMass),
          measured_mass_g: round(measuredMass),
          packaging_mass_ratio: round(massRatio),
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
