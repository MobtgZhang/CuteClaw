# 预制 Prompt 模板

- **`agent-system.zh.md`**：Agent 控制台聊天用的系统提示。占位符 **`{{SKILL_SUMMARY}}`** 由宿主替换为当前项目下扫描到的技能摘要列表。
- 修改后无需重新编译 Web；重启 **Agent 宿主**（`web/server/agent-host.ts`）后生效。
- 若文件缺失，宿主使用内置默认中文系统提示。

可选：自行增加 `agent-system.en.md` 等，需在宿主中增加语言/路径选择逻辑（当前仅读取 `agent-system.zh.md`）。
