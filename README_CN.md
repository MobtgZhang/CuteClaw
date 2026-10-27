# CuteClaw Design（中文版）

**专业领域**的设计 Agent：只做 **PCB** 与 **产品外壳 / 包装（CAD）**，不做通用任务 Agent。

Agent 核心层 **100% 是 Zig**：任务调度、LLM 调用、工具执行、插件管理、记忆、自进化与沙箱都在 Zig 内，无第三方依赖。界面是 **Vue 3 + TypeScript**（`apps/web`）。

English version: [README.md](README.md)。

## 它做什么

1. **理解设计** — 工程状态、设计约束、PCB 网络与飞线、外壳腔体。
2. **执行设计** — 真正读取并校验工程文件（KiCad、FreeCAD、STEP），而不是只给建议。
3. **用图执行设计过程** — 把工作先规划成可审阅的依赖图，再按层执行，并在人工审批门前停下（见 [Graph Flow / Graph Loop](#graph-flow--graph-loop)）。
4. **进化设计能力** — 借鉴 Harness² 的 `Propose → Probe → Compose → Evaluate → Promote`，用工程验证结果学习更好的策略。

一条不可协商的原则：自进化可以改写策略、技能与工具指引，但**绝不能**放宽安全间距、电气规则或结构干涉——guardrails 被排除在可编辑组件之外（`src/evolution/proposer.zig`）。

## 特点

- **纯 Zig Agent Host** — Agent 主循环、OpenAI 兼容 / Anthropic 兼容 LLM 客户端（非流式与 SSE）、会话消息链、带 guardrail 钩子的工具注册表、Cordis 风格事件总线、插件内核、按能力授予的沙箱。
- **规则写在代码里的 Agent Loop** — 终止条件必须是二元谓词、重试与停滞上限、hook 只能收紧决策、审批中 deny 永远优先于授权、压缩不能缩短审计轨迹、append-only 的检查点、从 0 上下文起步且写入边界互斥的子代理（见 [Agent Loop](#agent-loop)）。
- **硬约束优先** — 违反硬约束的候选在任何代价比较之前就被淘汰；飞线更短不能抵消 DRC 违规。
- **基于图的执行模型** — 从 GitHub 上真实 PCB / CAD / 包装工程 skill 中提炼的 54 个技能模板：叙述边识别、按层执行、可对状态求值的谓词路由、有界 verify/repair 回路、代码内的迭代上限。
- **兼容 DeepSeek Harness（Cordis）插件生态**，锁定 `manifestVersion 1`；插件进程只是被 Zig 调用的受控外部工具，不持有任何调度权。
- **确定性核心库** — 分层记忆、显式工作区、带门禁的技能进化、指标与审计、JSON 快照持久化（schema v1）。
- **服务端** — REST + SSE + WebSocket（`GET /api/ws`，文本帧按 JSON-RPC 处理），静态根即 Vue 构建产物。

## 要求

- [Zig](https://ziglang.org/) **0.17.0**（与 `build.zig.zon` 的 `minimum_zig_version` 一致）
- 前端可选：Node.js **20+**（`apps/web`）
- DSH 插件桥接可选：Node.js（桥接是被调用的外部工具进程，控制平面仍在 Zig）

## 快速开始

```bash
zig build
zig build test
bash tests/cli_smoke.sh zig-out/bin/cuteclaw

# 对话（单轮；不带 --message 进入交互式 REPL）
zig build run -- chat --message "帮我检查这块板的 DRC"

# 设计面：硬约束先淘汰，再按代价排序
zig build run -- design rank canonical \
  --constraints '[{"id":"drc","kind":"drc_errors","limit":0,"direction":"max","severity":"hard"},{"id":"rat","kind":"rat_length","limit":900,"direction":"max","severity":"soft"}]' \
  --file benchmarks/pcb/cases.json

# 对真实 KiCad 板执行 DRC
zig build run -- design drc canonical \
  --constraints '[{"id":"clearance","kind":"clearance","limit":0.3,"direction":"min","severity":"hard"}]' \
  --path benchmarks/pcb/canonical.kicad_pcb

# Graph Flow：先看工作形状，再决定要不要 fan-out
zig build run -- graph plan pcb-design-review
zig build run -- graph run graph-orchestrator
zig build run -- graph gate --measurements '[{"kind":"drc_errors","value":0,"ref":"board","measured":false}]'

# Agent Loop：plan mode 只读，措辞式终止条件一律拒绝
zig build run -- loop status
zig build run -- loop plan --input '{"goal":"pcb stackup","mode":"plan","tasks":[{"id":"t1","title":"stackup"}]}'
zig build run -- loop stop-check --input '{"rule":{"kind":"prose","criterion":"looks good enough"},"measurements":[]}'

# 插件（DeepSeek Harness / Cordis 兼容）
zig build run -- plugin load skills/design-review/package.json
zig build run -- plugin call design-review review --plugin skills/design-review/package.json \
  --args '{"candidates":[{"id":"A","measurements":{"drc_errors":0,"rat_length_mm":820}},{"id":"B","measurements":{"drc_errors":0,"rat_length_mm":670}},{"id":"C","measurements":{"drc_errors":3,"rat_length_mm":590}}],"limits":{"drc_errors":0}}'

# 服务 Vue 工作台（仅 127.0.0.1）
make app-build
zig build run -- serve --port 8788
```

一键校验：

```bash
make check      # build + test + smoke + dsh + benchmark + drc + schemas + graph
make live-chat  # 用测试 API（默认 /data/api.json）跑一轮真实对话
```

## 架构

```text
Vue 3 + TypeScript（apps/web）
        |  REST / SSE / WebSocket（JSON-RPC 帧）
        v
100% Zig Agent Host
  Agent 主循环 | 插件内核 | 设计引擎 | 进化引擎
  记忆 / 事件 | 安全 / 沙箱
        |
        +-- CAD / EDA 桥接：KiCad、FreeCAD、STEP（受控外部工具）
        +-- DSH 兼容桥接：Cordis 插件 bundle
        v
版本化设计产物
```

| 层 | 路径 | 职责 |
|----|------|------|
| Agent 主循环 | `src/core/agent.zig` | LLM 响应 → 工具执行 → 结果回写，直到无工具调用或达到轮次上限 |
| LLM 客户端 | `src/core/llm.zig` | `openai_compat` / `anthropic_compat`，非流式与 SSE |
| 会话 | `src/core/session.zig` | 消息链与 JSON 序列化，HTTP / WebSocket / 持久化共用；令牌上限来自 LLM 配置的 `max_tokens` |
| 工具 | `src/core/tools.zig` | 工具注册表，含 guardrail 前置/后置钩子与事件派发 |
| 事件 | `src/core/events.zig` | Cordis 风格派发模式（emit / waterfall / parallel / serial / bail）+ JSONL 事件日志 |
| 设计引擎 | `src/design/` | 工程状态、约束、几何、PCB/飞线、DRC 判定、工具面 |
| 适配器 | `src/adapters/` | `.kicad_pcb` 解析、FreeCAD 文档、STEP 几何 |
| 图执行 | `src/graph/` | 依赖图、分层、门、对抗性审查、结构化执行记录与检查点、技能目录 |
| 插件 | `src/plugins/` | Cordis/DSH manifest、权限、内核、MCP、桥接调用 |
| 沙箱 | `src/sandbox/policy.zig` | 能力集合 + 工作区路径边界（越界读取直接拒绝） |
| 进化 | `src/evolution/` | Propose–Probe–Compose–Evaluate–Promote，含门禁、版本历史与回滚 |
| 核心库 | `src/memory.zig`、`src/working.zig`、`src/evolution.zig`、`src/metrics.zig`、`src/claw.zig`、`src/persist.zig`、`src/config.zig` | 确定性记忆 / 门禁 / 指标 / 持久化（无 LLM、无网络） |
| 服务端 | `src/server/` | HTTP 路由、JSON-RPC、WebSocket 升级 |
| CLI | `src/main.zig`、`src/cli_*.zig` | 子命令入口 |

## 设计工具

暴露给模型的工具面（`src/design/tools.zig`）：

| 工具 | 作用 |
|------|------|
| `project_open` | 打开或创建设计工程 |
| `project_set_constraint` | 增加或更新一条设计约束 |
| `pcb_read` | 读取 KiCad `.kicad_pcb`（`path` 或 `text`），写入板框、器件与焊盘 |
| `drc_check` | 按工程约束执行 DRC，返回违规明细与是否通过 |
| `enclosure_fit` | 外壳腔体与 PCB 的配合间隙（负值 = 干涉） |
| `design_rank` | 先淘汰硬约束违规，再按代价排序候选 |
| `skill_list` | 列出可用技能（工作区 + 运行时记忆） |

约束类型覆盖 `trace_width`、`clearance`、`hole_diameter`、`board_area`、`rat_length`、`iterations`、`enclosure_wall`、`fit_clearance`、`courtyard_gap`、`board_margin`、`drc_errors`，每条都有 `min`/`max` 方向与 `hard`/`soft` 级别。飞线长度按每个网络的最小生成树计算。

## Graph Flow / Graph Loop（Graph Loop 执行模型）

设计过程不靠「模型自己判断够不够」，而是先把工作建成**可审阅的依赖图**，再按层执行。规划权在 Zig 侧：插件只提供能力，图决定什么先跑、什么可以 fan-out、什么必须停在人工审批门前。

两条原则：

1. **箭头只在工作真的流过去时才成立。** 上游既不产出 artifact、下游也没有读取 `node.<id>.`，这条边就只是叙述上的先后（narration edge），不构成执行约束，执行前必须删除。
2. **工作形状决定拓扑。** 只有真正独立的任务对才值得 fan-out；把串行工作排成图、再加团队，只会增加协调成本。Google DeepMind × MIT「Towards a Science of Scaling Agent Systems」的停止规则：可拆分的任务上团队约赢 80%，串行工作上每一种团队配置都会输。

任何副作用之前，`src/graph/gates.zig` 会检查这些不可协商的规则：

- 每个技能必须有**可验证的二元终止条件**和写在代码里的迭代上限；
- `verify` 必须从声明的源依赖重新推导，不能确认自己的合成结果；
- `gate` 必须有依赖：门不能悬空自确认；
- 含 `transform` 能力的 work 节点必须有 `calibrate` 依赖：先校验工具，再校验结果；
- fan-in 必须进多少出多少；超过批大小宁可多跑一轮，不能静默丢条目；
- 不可逆动作（下单、把文件发给供应商、落库）必须有传递性的审批祖先；
- 推断值（`measured = false`）不能通过 measured-only 硬门；
- 条件路由：下一层跑什么必须由实测结果决定，而不是叙述顺序——未被路由选中的分支不执行，也不计入 fan-in 的「进多少出多少」；`verify` 与 `approval` 不属于分支候选，必须始终执行。

工具面（`src/graph/tools.zig`，与 Agent、插件共用同一入口和权限检查）：`graph_skills`、`graph_plan`、`graph_run`、`graph_gate`、`graph_checkpoint`。

技能目录：`src/graph/skills.zig` 共 **54 项** — 图执行与回路 25 项、PCB / 电子 13 项、CAD / 机械 11 项、包装 5 项，来自 `reports/plan-3.md` 的 8 个工程 Skills 加上在 GitHub 上大量筛选的真实工程 skill。完整出处、star 数与 plan-3 五类工具的映射见 [docs/graph-flow.md](docs/graph-flow.md)。

五种回路模式，每一种都必须有可验证退出条件与硬上限：`headless while-loop`、`evaluator-optimizer`（生成与评审分离）、`meta / prompt-refine`、`orchestrator fan-out`、`scheduled / triggered`。`loop-pattern-picker` 按工作形状选模式，`graph-runtime-audit` 报告运行时实际执行了什么。

检查点：`graph run` 把执行记录写入内存与 `CUTECLAW_CHECKPOINT_DIR`（或 `--checkpoint-dir`）。检查点包含 `results`（已完成节点）与 `pending`（还欠哪些节点）——**检查点不是完成的证明**。`graph run --resume` 从检查点恢复，且不会重跑已完成节点。

```bash
zig build run -- graph skills
zig build run -- graph plan work-shape-audit          # 叙述边 vs 真实边
zig build run -- graph run signal-integrity-review
zig build run -- graph run durable-state-loop demo --resume
zig build run -- graph checkpoint graph-orchestrator  # 还欠哪些节点
```

## Agent Loop

图决定**跑什么**，回路决定**跑的时候允许做什么**。`src/loop/` 落地了从 Claude Code、Codex 与 Hermes Agent 取来的运行期规则，并且每条规则都由代码判定，而不是交给模型自己判断：

- 终止条件必须是**可判定的二元谓词**——prose 规则（“差不多了”）在任何副作用之前就被拒绝；
- 每个工具的重试有上限；同一工具同一参数连续出现两次判 stall，连续多步没有新的实测事实判 no progress；中断立刻改道，排队消息只在当前步结束后处理；
- hook 沿用 Claude Code 的退出码语义（`0` 放行、`2` 拒绝），并且只能**收紧**决策，不能放宽硬门——试图放宽的 hook 结论记为 `ignored_grants` 并忽略；复合命令逐段检查（`&&`、`||`、`;`、`|`、换行），`echo ok && rm -rf` 这种绕过会被整条拒绝；
- 审批模式（`never` / `on_request` / `untrusted`）中 deny 永远优先于 allow 规则与会话级授权；不可逆动作即使在“总是允许”下也必须问人；
- 压缩按令牌预算执行，但**不能缩短审计轨迹**；受保护项（system 提示词、终止条件、门失败记录、计划、最近 N 轮）必须原样保留；
- 每轮一个检查点；不可逆效果拒绝回退——推上去的提交、发出去的请求，恢复文件内容救不回来；飞行记录器是 append-only；
- 子代理从 0 上下文起步、写入边界必须互斥、阻塞主任务的子任务不能委派、计划评审通过前不派发、结果评审通过前不合并；
- `SKILL.md`（agentskills.io 标准）是描述层并按需加载——未触发的技能不占上下文；Cordis `package.json` 的 `manifestVersion 1` 仍是运行时契约，两者共存且不能互相替代；
- 学习回路（轨迹捕获、复杂任务后自主起草技能、周期性 nudge）永远不能写入 guardrail 前缀。

工具面（`src/loop/tools.zig`，与 Agent 和插件共用同一入口和权限检查）：`loop_plan`、`loop_delegate`、`loop_compact`、`loop_checkpoint`、`loop_stop_check`、`loop_hooks`、`loop_approval`、`loop_skills`。

```bash
zig build run -- loop status
zig build run -- loop plan --input '{"goal":"enclosure fit","mode":"plan","tasks":[{"id":"t1","title":"wall thickness"}]}'
zig build run -- loop delegate --input '{"tasks":[{"id":"a","goal":"route","write_scope":["src/graph"]},{"id":"b","goal":"review","write_scope":["src/graph/gates.zig"]}],"review":{"stage":"plan_review","passed":true}}'
zig build run -- loop approval --input '{"mode":"untrusted","tool":"shell","command":"git reset --hard HEAD","rules":[{"tool":"*","pattern":"git","decision":"allow"}],"grants":[{"tool":"*","pattern":"git"}]}'
```

详见 [docs/agent-loop.md](docs/agent-loop.md)；冒烟测试 `tests/agent_loop.sh`（`make loop`）。

## 进化引擎

Harness² 的可编辑组件（`src/evolution/proposer.zig`）：`system_prompt`、`guardrails`、`memory`、`tool_guidance`、`subagents`、`skills`、`scripts`、`plugins`——其中只有 `guardrails` 被锁定。

晋升门禁使用的指标（`src/evolution/evaluator.zig`）：

| 指标 | 衡量目标 |
|------|----------|
| Engineering Pass Rate | 满足硬性工程约束的任务比例 |
| Design Quality | 相对基线的设计质量改善（>1 表示改善） |
| Tool Reliability | CAD/EDA 工具调用成功率 |
| Iterations to Pass | 达到合格设计所需迭代次数 |
| Regression Rate | 新技能在历史任务上的退化比例 |
| Human Acceptance | 工程师认可或采纳设计的比例 |

晋升（`src/evolution/promotion.zig`）复用核心 `MergePolicy`（`dry_run` / `require_human` / `auto_append_only`），每次合并写一条审计，并保留回滚引用。判断进步是否真实必须使用固定的未见任务测试集（`benchmarks/pcb/`）。

基准的典型结论：`B` 胜出（代价 670），`C` 被淘汰——尽管它的飞线更短，但违反了硬 DRC 约束。

## DeepSeek Harness（Cordis）插件兼容

兼容边界锁定 **manifestVersion 1**，分两级：

1. **Level 1（纯 Zig）**：`src/plugins/manifest.zig` 解析 `package.json` 的 `dsh` 字段与 `cordis.patch.yml`；未知字段忽略但保留原始文本。
2. **Level 2（桥接进程）**：`bridges/deepseek-harness/bridge.mjs` 在独立进程中加载插件 bundle，由 `src/plugins/dsh_bridge.zig` 调用。

桥接协议：

```text
stdin  -> {"plugin":"<id>","tool":"<name>","args":{...}}
stdout -> {"jsonrpc":"2.0","ok":true,"content":"...","meta":{...}}
```

环境变量：`PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT`、`CUTECLAW_PLUGIN_ID`、`CUTECLAW_TOOL`。

错误也是一条响应：桥接进程把 JSON-RPC 错误对象写到 stdout 并正常退出，这样 Zig 宿主能把错误码原样转给调用方，而不是只看到一个进程退出码。

| 码 | 含义 |
|----|------|
| `-32700` | stdin 解析错误 |
| `-32601` | 插件未注册该工具 |
| `-32602` | 处理函数失败 |
| `-32603` | 内部错误 |

能力在插件清单中声明，并映射到沙箱能力枚举（`src/plugins/permissions.zig`、`src/sandbox/policy.zig`）：`read_file`、`write_file`、`run_tool`、`network`、`plugin_exec`、`design_edit`、`evolve_write`；不在此集合内的名称会被忽略。文件路径必须落在工作区根内。示例插件：`skills/design-review`、`skills/pcb-layout`、`skills/enclosure-design`。

## CLI

全局选项（多数子命令可用）：**`--store PATH`**（`CUTECLAW_STORE`，默认 `.cuteclaw/store.json`）与 **`--config PATH`**（`CUTECLAW_CONFIG`，默认 `.cuteclaw/config.json`）。

| 命令 | 作用 |
|------|------|
| `init` / `status` / `export` / `import` | 快照生命周期 |
| `demo` | 演示并写入默认快照 |
| `evolve --file F --policy P --semver V` | 权威的提议校验与合并 |
| `validate --file F` | 仅运行 `checkProposal` |
| `task <id> <outcome> <summary...>` | 追加情景记录 |
| `invoke <name> <ok\|fail>` | 记录技能调用 rollup |
| `working show` / `working set <field> <文本...>` | 工作区（`goal` / `constraints` / `confirmed_facts` / `next_step`） |
| `fact add <key> <value...>` | 追加语义事实 |
| `memory list\|get\|put\|rm` | Agent cache 下的 memory 文件（`--cache`、`--project`） |
| `agent-tool` | stdin 一行 JSON、stdout 一行 JSON；供宿主 function calling 使用 |
| `config show` / `config init` / `config validate` | API 配置（不输出密钥内容） |
| `chat [--message TEXT]` | 单轮对话，或交互式 REPL；`--session`、`--json` |
| `plugin list\|load\|enable\|disable\|call` | DSH/Cordis 兼容插件 |
| `design open\|constraint\|read\|drc\|fit\|rank\|skills` | 工程、约束、KiCad 读取、DRC、外壳配合、候选排序 |
| `graph skills\|plan\|run\|gate\|checkpoint` | Graph Flow：技能目录、工作形状审计、按层执行、硬门、检查点续跑（`--checkpoint-dir`、`--resume`） |
| `loop status\|plan\|delegate\|compact\|checkpoint\|stop-check\|hooks\|approval\|skills` | Agent Loop：计划、子代理派发、压缩审计、检查点、二元终止判定、hook、审批、`SKILL.md`（`--input JSON`） |
| `serve [--port N]` | 仅 `127.0.0.1` 的 HTTP + SSE + WebSocket（默认 8788 或 `CUTECLAW_SERVE_PORT`） |
| `version` / `help` | 版本与用法 |

退出码：`0` 成功；`1` 校验或业务拒绝；`2` 用法、I/O 或解析失败，详见 [docs/cli-exit-codes.md](docs/cli-exit-codes.md)。

## HTTP 与 WebSocket API

| 端点 | 说明 |
|------|------|
| `GET /api/health` | 状态、版本、模型、会话/工具/插件数量 |
| `GET /api/sessions`、`/api/tools`、`/api/plugins`、`/api/metrics` | 只读视图 |
| `POST /api/chat` | `{session, message}` → 回复、轮次、工具调用、outcome |
| `POST /api/chat/stream` | SSE 事件：`session`，随后 `delta` / `reasoning` / `tool_call`，最后 `assistant` 与 `done` |
| `POST /api/drc` | 请求体可以是工程对象本身，或 `{"project": {...}}` |
| `POST /api/kicad` | `{"text": "<kicad_pcb 内容>"}` |
| `GET /api/ws` | WebSocket 升级，文本帧按 JSON-RPC 处理 |
| `GET /*` | 静态资源（`apps/web/dist`），拒绝 `..` 越界 |

旧路由（`/health`、`/store`、`/status`、`POST /evolve`）为遗留控制台保留。

WebSocket 升级后使用直接的 socket 读写（不经过 `std.Io` 缓冲），长连接、粘包、ping/pong 与 close 回显均按 RFC 6455 处理；握手 GUID 为 `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`。

## 前端

`apps/web`（Vue 3 + TypeScript + Vite）。面板：`ChatPanel`、`ToolPanel`、`PluginPanel`、`ValidationPanel`、`MetricsPanel`。

```bash
cd apps/web
npm install        # make app-install
npm run build      # make app-build（vue-tsc --noEmit && vite build）
npm run dev        # make app-dev（Vite 5173，/api 代理到 8788）
```

端口环境变量 **`VITE_API_PORT`**（默认 `8788`）。遗留的 React 控制台仍在 `web/`，两者互不影响。

## 数据契约与基准

- `schemas/design_task.json`、`schemas/tool_result.json`、`schemas/evolution_record.json`（`make schemas` 校验）。
- `benchmarks/pcb/` — 固定任务集与 KiCad 样例（`cases.json`、`canonical.kicad_pcb`、`fit.kicad_pcb`）。
- 快照格式（schema v1）见 [docs/format.md](docs/format.md)：原子写入，并由 `store.json.lock` 咨询锁保护。

## 测试

```bash
make check
```

会执行 `zig build`、`zig build test`（`src/` 下 124 个测试块，外加 CLI 入口），以及以下脚本：

| 脚本 | 断言内容 |
|------|----------|
| `tests/cli_smoke.sh` | 快照生命周期、配置校验、工作区、事实、提议门禁、退出前用法提示已 flush |
| `tests/dsh_bridge.sh` | 插件加载与调用、排序结论正确、未知工具返回 `-32601` |
| `tests/design_benchmark.sh` | 硬约束先淘汰再比较代价；插件结论与基准一致 |
| `tests/design_drc.sh` | 硬违规被报告、干净板通过 DRC、配合间隙为正 |
| `tests/schemas.sh` | Schema 的 required / properties 数量 |
| `tests/graph.sh` | 54 项技能目录、叙述边识别、执行停在审批门前、检查点跨进程续跑、measured-only 硬门、条件路由、插件工具 |
| `tests/live_chat.sh` | 用测试 API 跑真实对话与工具回路；不可达则跳过 |
| `tests/agent_web_fetch_search.sh` | 通过 `agent-tool` 的 `web_fetch` 做网络 + TLS 冒烟（需外网） |

## 目录结构

```text
src/            Zig 核心库 + Agent Host
  core/         agent 主循环、llm、session、tools、events、jsonutil
  design/       工程、约束、几何、PCB、校验、工具面
  graph/        图模型、执行记录与检查点、门、执行器、技能目录、工具面
  adapters/     kicad、freecad、step
  plugins/      manifest、权限、registry、mcp、内核、桥接
  sandbox/      能力与路径策略
  evolution/    proposer、probe、composer、evaluator、promotion
  server/       http、rpc、websocket、serve
apps/web/       Vue 3 + TypeScript 工作台
bridges/        DeepSeek Harness（Cordis）桥接进程
skills/         示例插件
schemas/        JSON Schema 契约
benchmarks/     固定基准任务集
prompts/        Agent 系统提示模板
docs/           架构、格式、上手、插件与前端文档
tests/          测试脚本
web/            遗留 React 控制台
reports/        规划文档（plan-1、plan-2）
```

## 文档

索引见 [docs/README.md](docs/README.md)。最常看的几篇：[docs/architecture.md](docs/architecture.md)、[docs/graph-flow.md](docs/graph-flow.md)、[docs/design-agent.md](docs/design-agent.md)、[docs/dsh-plugins.md](docs/dsh-plugins.md)、[docs/vue-app.md](docs/vue-app.md)、[docs/quickstart.md](docs/quickstart.md)、[docs/format.md](docs/format.md)、[docs/roadmap.md](docs/roadmap.md)。

变更摘要见 [CHANGELOG.md](CHANGELOG.md)；版本单一来源是 `src/version.zig`。

## 许可

[Apache License 2.0](LICENSE)。
