# Agent Loop（运行期规则）

图决定**跑什么**，回路决定**跑的时候允许做什么**。`src/loop/` 把 Claude Code、Codex、Hermes Agent 与 harness2 里可执行的运行期规则落成代码，每条规则都由代码判定，不交给模型自己判断。

规划权仍在 Zig 侧：插件与技能只提供能力，回路决定什么能跑、什么必须停在人工审批门前。

## 模块

| 路径 | 职责 |
|------|------|
| `src/loop/agent_loop.zig` | 主循环：hook → 审批 → 执行 → 记录；二元终止条件、每工具重试上限、stall 与 no-progress 判定、中断与排队消息 |
| `src/loop/hooks.zig` | 事件 → 匹配器 → 动作；退出码语义（`0` 放行、`2` 拒绝）；只能收紧决策；复合命令逐段检查 |
| `src/loop/approval.zig` | 模式（`never` / `on_request` / `untrusted`）+ 规则（allow/ask/deny）+ 会话级授权；deny 优先；不可逆动作必须问人 |
| `src/loop/compaction.zig` | 按令牌预算压缩最旧的工具输出；受保护项不可压缩；审计轨迹不能变短 |
| `src/loop/checkpoint.zig` | 每轮一个检查点；先看 diff 再决定能否回退；不可逆效果拒绝回退；飞行记录器 append-only |
| `src/loop/planning.zig` | plan mode 只读；任务状态机；blocked 必须同一条件连续满 3 次；计划文件先写 `.tmp` 再 rename |
| `src/loop/subagent.zig` | 子代理从 0 上下文起步；写入边界互斥；并发上限；两段式评审门 |
| `src/loop/learning.zig` | 轨迹捕获与压缩、复杂任务后自主起草技能、自我改进计数、会话倒排索引检索、周期性 nudge；guardrail 前缀不可写 |
| `src/loop/skillfile.zig` | `SKILL.md`（frontmatter 只有 name 与 description）+ progressive disclosure；与 Cordis `manifestVersion 1` 共存 |
| `src/loop/tools.zig` | 注册给模型的工具面，与 Agent、插件共用同一入口和权限检查 |
| `src/cli_loop.zig` | CLI 子命令：`status` / `plan` / `delegate` / `compact` / `checkpoint` / `stop-check` / `hooks` / `approval` / `skills` |

## 不可协商的规则

- 终止条件必须是**可判定的二元谓词**：prose 规则一律拒绝（`ProseStopRuleRejected`），不能靠模型说「差不多了」。
- 每个工具的重试有上限（`max_retries_per_tool`）；同一工具同一参数连续出现两次判 stall；连续多步没有新的实测事实判 no progress。
- hook 只能收紧决策，不能放宽决策，也不能改写硬门（`hooks_can_override_gates = false`）。任何试图放宽的 hook 结论记为 `ignored_grants` 并忽略。
- 复合命令逐段检查（`&&`、`||`、`;`、`|`、换行），任一段命中拒绝模式即整条拒绝。
- deny 规则永远优先于 allow 规则与会话级授权；不可逆动作在任何模式下都必须人工确认，会话级授权覆盖不到它。
- 压缩不能丢审计轨迹：每条被压缩的内容都留下一条 audit 条目；某次压缩会让审计变短即判失败。
- 回退只恢复文件内容，不能把世界恢复到动作之前：推上去的提交、发出去的请求、被覆盖的远端状态一律拒绝回退。
- 子代理不继承会话历史；写入边界重叠即判冲突；阻塞主任务的子任务不能委派；计划评审通过前不派发，结果评审通过前不合并。
- guardrails 不可被学习回路改写：任何写入 guardrail 前缀的请求都被拒绝。

## 参考来源与差异

| 来源 | 取用的机制 | 本项目的差异 |
|------|-----------|--------------|
| Claude Code | hook 退出码语义（0/2）、plan mode 只读、subagent、`SKILL.md`（agentskills.io） | hook 只能收紧；`SKILL.md` 是描述层，不能替代 DSH manifest 契约 |
| Codex | 审批模式（never / on_request / untrusted）、检查点与 rewind、飞行记录器 | 不可逆效果拒绝回退；飞行记录器 append-only |
| Hermes Agent | 自进化技能、复杂任务后自主起草技能、周期性 nudge、倒排索引检索 | guardrail 前缀不可被学习回路写入 |
| harness2 | Propose → Probe → Compose → Evaluate → Promote、冻结的未见评估集 | 与 `src/evolution/` 共用同一套 guardrail 口径 |

## 工具面

`loop_plan`、`loop_delegate`、`loop_compact`、`loop_checkpoint`、`loop_stop_check`、`loop_hooks`、`loop_approval`、`loop_skills`。

## CLI

```bash
zig build run -- loop status
zig build run -- loop plan --input '{"goal":"enclosure fit","mode":"plan","tasks":[{"id":"t1","title":"wall thickness"}]}'
zig build run -- loop delegate --input '{"tasks":[{"id":"a","goal":"route","write_scope":["src/graph"]},{"id":"b","goal":"review","write_scope":["src/graph/gates.zig"]}],"review":{"stage":"plan_review","passed":true}}'
zig build run -- loop compact --input '{"items":[{"kind":"tool_output","turn":1,"content":"..."}],"budget_tokens":1000,"protected_last_n":1}'
zig build run -- loop checkpoint --input '{"turn":1,"entries":[{"path":"origin/main","before":"c1","after":"c2","irreversible":true}],"rewind":true}'
zig build run -- loop stop-check --input '{"rule":{"kind":"binary","constraint_kind":"drc_errors","limit":0,"direction":"max","severity":"hard"},"measurements":[{"kind":"drc_errors","value":0,"ref":"board","measured":true}]}'
zig build run -- loop hooks --input '{"event":"pre_tool","tool":"shell","command":"echo ok && rm -rf build","deny_patterns":["rm -rf"]}'
zig build run -- loop approval --input '{"mode":"untrusted","tool":"shell","command":"git reset --hard HEAD","rules":[{"tool":"*","pattern":"git","decision":"allow"}],"grants":[{"tool":"*","pattern":"git"}]}'
zig build run -- loop skills --input '{"dir":"skills","positives":["review the pcb stackup"],"negatives":["write a blog post about the sea"]}'
```

## 测试

- 单元测试：`src/loop/*.zig`（由 `tests.zig` 收集执行）。
- 冒烟：`tests/agent_loop.sh`（`make loop`，已纳入 `make check`）。

> 注意：回路工作区只在单个进程内存在，跨进程状态由检查点承载（`CUTECLAW_CHECKPOINT_DIR`）。
