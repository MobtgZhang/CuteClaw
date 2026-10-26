// DeepSeek Harness（Cordis）兼容插件：产品外壳（包装）设计技能。

export const name = 'enclosure-design';
export const inject = ['tools', 'effect'];

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'enclosure' });

  ctx.tools.register({
    name: 'generate',
    description: '由 PCB 尺寸生成外壳腔体参数（壁厚、间隙、开孔）',
    schema: {
      type: 'object',
      properties: {
        pcb_length: { type: 'number' },
        pcb_width: { type: 'number' },
        pcb_height: { type: 'number' },
        wall: { type: 'number' },
        clearance: { type: 'number' },
      },
    },
    handler: async (args) => {
      const wall = Number(args.wall) || 2.0;
      const clearance = Number(args.clearance) || 1.5;
      const L = Number(args.pcb_length) || 0;
      const W = Number(args.pcb_width) || 0;
      const H = Number(args.pcb_height) || 0;
      const cavity = {
        length: L + 2 * clearance,
        width: W + 2 * clearance,
        height: H + clearance + wall,
      };
      const outer = {
        length: cavity.length + 2 * wall,
        width: cavity.width + 2 * wall,
        height: cavity.height + 2 * wall,
      };
      return {
        content: `外壳 ${outer.length.toFixed(1)} x ${outer.width.toFixed(1)} x ${outer.height.toFixed(1)} mm（壁厚 ${wall} mm）`,
        meta: { wall, clearance, cavity, outer, fit: L > 0 && W > 0 && H > 0 },
      };
    },
  });
}
