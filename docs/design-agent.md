# 设计 Agent（专业领域，不做通用任务）

CuteClaw 只做两件事：**理解设计**与**执行设计**——PCB 与产品外壳（CAD）。控制平面全部在 Zig 内，LLM 客户端、工具回路、约束判定、进化门禁都是纯 Zig，无第三方依赖。

## 模块

| 路径 | 职责 |
|------|------|
| `src/core/agent.zig` | Agent 主循环：LLM 响应 → 工具执行 → 结果回写，直到无工具调用或达到轮次上限 |
| `src/core/llm.zig` | OpenAI 兼容 / Anthropic 兼容客户端，非流式与 SSE 流式 |
| `src/core/session.zig` | 消息链与 JSON 序列化（HTTP / WebSocket / 持久化共用）；令牌上限来自 LLM 配置的 `max_tokens` |
| `src/core/tools.zig` | 工具注册表，含 guardrail 前置/后置钩子与事件派发 |
| `src/core/events.zig` | Cordis 风格事件总线（emit / waterfall / parallel / serial / bail）+ JSONL 事件日志 |
| `src/design/constraints.zig` | 约束模型：**硬约束先淘汰，软约束再按代价排序** |
| `src/design/geometry.zig` | 点、矩形、多边形、距离（PCB 与外壳配合共用） |
| `src/design/pcb.zig` | 板框、器件、焊盘、网络与飞线（每网络最小生成树长度） |
| `src/design/project.zig` | 工程状态、版本、约束集合 |
| `src/design/validation.zig` | DRC 判定与违规明细 |
| `src/design/tools.zig` | 注册给模型的工具面 |
| `src/adapters/kicad.zig` | `.kicad_pcb` 解析 |
| `src/adapters/freecad.zig` | FreeCAD 文档/步骤模型读取 |
| `src/adapters/step.zig` | STEP 几何读取 |
| `src/sandbox/policy.zig` | 工作区边界：相对根以进程当前目录为基准，越界读取直接拒绝 |

## 工具面

`project_open`、`project_set_constraint`、`pcb_read`、`drc_check`、`enclosure_fit`、`design_rank`、`skill_list`。

## 不可协商的原则

自进化可以改写策略、技能与工具指引，但**不能为了评分自动放宽安全间距、电气规则或结构干涉**。硬约束与 guardrail 在 `src/evolution/proposer.zig` 中被排除在可编辑组件之外。

## 命令示例

```bash
# 硬约束优先淘汰，再比较优化指标（C 飞线更短但违反 DRC，必须被淘汰）
zig build run -- design rank canonical \
  --constraints '[{"id":"drc","kind":"drc_errors","limit":0,"direction":"max","severity":"hard"},{"id":"rat","kind":"rat_length","limit":900,"direction":"max","severity":"soft"}]' \
  --file benchmarks/pcb/cases.json

# DRC：读取 KiCad 板并判定违规
zig build run -- design drc canonical \
  --constraints '[{"id":"drc","kind":"drc_errors","limit":0,"direction":"max","severity":"hard"},{"id":"clearance","kind":"clearance","limit":0.3,"direction":"min","severity":"hard"},{"id":"margin","kind":"board_margin","limit":1.0,"direction":"min","severity":"soft"}]' \
  --path benchmarks/pcb/canonical.kicad_pcb

# 外壳配合（负间隙 = 干涉）
zig build run -- design fit demo 48 38 2 --shell-height 15 --path benchmarks/pcb/fit.kicad_pcb
```

对应脚本：`tests/design_benchmark.sh`、`tests/design_drc.sh`（`make benchmark` / `make drc`）。

## 进化引擎（Harness²）

`src/evolution/` 实现 Propose → Probe → Compose → Evaluate → Promote：

- `proposer.zig` 从任务证据生成候选改动，可编辑组件不含 guardrails 与硬设计规范；
- `probe.zig` 把候选跑在固定任务集（含未见基准任务）上，记录证据；
- `composer.zig` 合并为 harness 配置补丁集；
- `evaluator.zig` 按 plan-1 的六项指标评估（工程通过率、设计质量、工具可靠性等）；
- `promotion.zig` 指标门禁 + 版本历史 + 回滚，复用 `src/evolution.zig` 的合并策略与审计。

## 数据契约

`schemas/design_task.json`、`schemas/tool_result.json`、`schemas/evolution_record.json`（`make schemas` 校验）。
