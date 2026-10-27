// DeepSeek Harness（Cordis）兼容插件：工程图成套性核对。
// 索引里存在的图必须在文件里真实存在；标题栏凭记忆填写不算证据。

export const name = 'drawing-set-index';
export const inject = ['tools', 'effect'];

const REQUIRED_TITLE_BLOCK_FIELDS = ['scale', 'units', 'author', 'date', 'revision'];

export async function apply(ctx) {
  ctx.effect('skill', { skill: name, kind: 'drawing-set' });

  ctx.tools.register({
    name: 'index',
    description: '把图纸索引与实际图纸逐张核对：缺图、未登记的图、标题栏缺项、无日期或无作者的修订都算问题',
    schema: {
      type: 'object',
      properties: {
        index: { type: 'array' },
        sheets: { type: "array" },
        required_fields: { type: 'array' },
      },
    },
    handler: async (args) => {
      const index = Array.isArray(args.index) ? args.index : [];
      const sheets = Array.isArray(args.sheets) ? args.sheets : [];
      const required = Array.isArray(args.required_fields) && args.required_fields.length > 0
        ? args.required_fields
        : REQUIRED_TITLE_BLOCK_FIELDS;

      if (index.length === 0 || sheets.length === 0) {
        return {
          content: '缺少图纸索引或实际图纸：成套性无法核对',
          meta: { error: 'unmeasured_input', findings: [], passed: false },
        };
      }

      const findings = [];
      const indexed = new Set();

      for (const entry of index) {
        const sheet = String(entry.sheet ?? '');
        if (!sheet) {
          findings.push({ kind: 'index_entry_without_sheet', value: 0, measured: false, severity: 'hard' });
          continue;
        }
        indexed.add(sheet);

        // 索引条目必须对应真实存在的图纸：这是可核对的事实，不是命名约定。
        if (!sheets.includes(sheet)) {
          findings.push({ kind: 'missing_sheet', sheet, value: 0, measured: true, severity: 'hard' });
        }

        const titleBlock = entry.title_block || {};
        for (const field of required) {
          const value = titleBlock[field];
          if (value === undefined || value === null || value === '') {
            findings.push({ kind: 'incomplete_title_block', sheet, field, value: 0, measured: false, severity: 'hard' });
          }
        }

        // 修订记录必须可追溯：没有日期或作者的修订不能当作已发生的变更。
        const revision = entry.revision || {};
        if (!revision.date) {
          findings.push({ kind: 'revision_without_date', sheet, value: 0, measured: false, severity: 'hard' });
        }
        if (!revision.author) {
          findings.push({ kind: 'revision_without_author', sheet, value: 0, measured: false, severity: 'hard' });
        }
      }

      // 实际存在但没进索引的图纸：索引不完整，同样算失败。
      for (const sheet of sheets) {
        if (!indexed.has(String(sheet))) {
          findings.push({ kind: 'unindexed_sheet', sheet: String(sheet), value: 0, measured: true, severity: 'hard' });
        }
      }

      return {
        content: `图纸索引 ${index.length} 条 / 实际图纸 ${sheets.length} 张；问题 ${findings.length}`,
        meta: {
          index_entries: index.length,
          sheets: sheets.length,
          matched: index.filter((entry) => sheets.includes(String(entry.sheet ?? ''))).length,
          findings,
          passed: findings.length === 0,
        },
      };
    },
  });
}
