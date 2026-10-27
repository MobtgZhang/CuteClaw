# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号与 `src/version.zig` / `build.zig.zon` 一致。

## [Unreleased]

### Added

- Agent Loop 运行期规则层：`src/loop/`（二元终止条件与重试/stall/no-progress 上限、hook 只能收紧、审批模式与不可逆动作、压缩审计轨迹、每轮检查点与回退、计划状态机、子代理写入边界、学习回路的 guardrail、`SKILL.md` progressive disclosure）与 CLI 子命令 `loop status|plan|delegate|compact|checkpoint|stop-check|hooks|approval|skills`
- 每个技能目录补上 `SKILL.md`（描述层，agentskills.io 标准：frontmatter 只有 name 与 description，正文按需加载），与 Cordis `package.json` 的 `manifestVersion 1` 运行时契约共存；触发词同时取自描述与技能名（`pcb`、`drc` 这类领域缩写是标识符，不是停用词）
- 回路工具面注册进宿主：`Host` 持有 `loop.Workspace`，`ToolCtx` 注入 `loop_workspace`，三层工具面（design / graph / loop）共用同一注册表与同一套能力检查
- 冒烟测试 `tests/agent_loop.sh`（`make loop`，已纳入 `make check`）与文档 `docs/agent-loop.md`
- Graph Flow / Graph Loop 执行层：`src/graph/`（图模型与叙述边识别、结构化执行记录与检查点、硬门与对抗性审查、按层执行的 Graph Loop、技能目录、工具面）与 CLI 子命令 `graph skills|plan|run|gate|checkpoint`
- 技能目录 54 项（图执行与回路 25、PCB / 电子 13、CAD / 机械 11、包装 5）：`reports/plan-3.md` 的 8 个工程 Skills 加上从 GitHub 大量筛选的真实 PCB / CAD / 包装工程 Agent Skills（PDN 目标阻抗、工厂能力逐项对照、工程图与 GD&T、无头 EDA 先校验工具、条件路由、不可被糊弄的门、上下文隔离、记忆本体层、包装运输测试、每步后的人工门、参数化模型重跑复现、工程图成套性与图纸索引、实测 DfAM 切片、循环经济性评分、技能出处与完整性校验、工具后置条件契约、冻结的未见测试集与独立评估者、Propose→Probe→Compose→Reflect 的进化回路、技能触发的正/负例测试、交付前的固定门集合、可对执行状态求值的谓词路由、高风险计划执行前的独立评审门、规格声明的状态转移、必须由可复现求解运行产生的仿真证据）
- 新 Cordis 插件：`skills/ground-truth-evaluator`（评估者不能是生成者自己，测试集不可因跑不过而被改写）、`skills/publish-gate-set`（固定门集合必须逐项真的跑过，自行豁免判失败）、`skills/predicate-router`（分支由可对状态求值的谓词决定，措辞式路由判失败并回退默认分支）、`skills/fea-simulation-evidence`（网格与边界条件必须记录，非求解器结果、未收敛、超屈服判失败）、`skills/pdn-impedance`（从实测去耦与回路电感推导目标阻抗、按 IPC-2221 反推载流宽度）、`skills/fabrication-capability-check`（设计规则与工厂公布能力逐项对照，缺少能力条目不算通过）、`skills/eco-packaging-score`（按实际材料成分与装载质量计算循环经济性评分，复合材质按不可回收处理）、`skills/drawing-set-index`（图纸索引与实际图纸逐张核对，标题栏缺项与无日期修订判失败）、`skills/parametric-model-rebuild`（重跑脚本后的尺寸与目标逐项对照，测不到、推断、超差都判失败）
- 专业设计核（只做 PCB 与产品外壳，不做通用任务）：`src/design/`（工程、约束、几何、PCB/飞线、DRC、工具面）与 `src/adapters/`（KiCad `.kicad_pcb`、FreeCAD、STEP）
- 纯 Zig Agent Host：`src/core/`（Agent 主循环、OpenAI/Anthropic 兼容 LLM 客户端、会话与令牌预算、工具注册表、Cordis 风格事件总线）
- DeepSeek Harness（Cordis，manifestVersion 1）插件兼容：`src/plugins/`（manifest、权限、内核、MCP、桥接调用）+ `bridges/deepseek-harness/bridge.mjs`
- Harness² 式进化引擎：`src/evolution/`（Propose–Probe–Compose–Evaluate–Promote），guardrails 与硬约束不可被自进化改写
- CLI 子命令：`chat`（单轮与交互式 REPL）、`plugin`、`design`
- `serve`：`/api/chat`、`/api/chat/stream`（SSE）、`/api/drc`、`/api/kicad`、`/api/ws`（WebSocket，文本帧按 JSON-RPC 处理），静态根默认 `apps/web/dist`
- Vue 3 + TypeScript 工作台 `apps/web`（遗留 React 控制台仍在 `web/`）
- 数据契约 `schemas/`、基准 `benchmarks/pcb/`、示例插件 `skills/`
- Make 入口：`check`、`dsh`、`benchmark`、`drc`、`schemas`、`graph`、`live-chat`、`app-install`、`app-build`、`app-dev`
- 文档：`docs/design-agent.md`、`docs/dsh-plugins.md`、`docs/vue-app.md`、`docs/graph-flow.md`（plan-3 五类工具与 8 个 Skills 的映射、技能目录、GitHub 来源与 star 快照、五种回路模式、检查点与续跑）
- GitHub 检索结论（2026-10 快照）：纯工程计算类 agent skill（SPICE、热仿真、爬电距离/电气间隙、via stub、ISTA 跌落、条码预飞、瓦楞 ECT）几乎没有成规模的仓库，成规模的是 EDA / CAD 无头自动化与执行治理类 skill；因此工程计算留在 Zig 侧的确定性插件里，治理规则落成图

### Changed

- 迁移到 Zig 0.17.0：`build.zig.zon` 的 `minimum_zig_version`、`Makefile` 与 README 的版本口径同步；`std.fs.File/Dir`、`std.time.*`、`std.process.getEnvVarOwned`、`std.process.Child.collectOutput`、`std.Thread.sleep`、`std.io.fixedBufferStream`、`std.mem.trimLeft/Right` 等已移除或改形的 API 统一经 `src/ioctx.zig` 适配（具名构建模块，测试根与 exe 根都注入）
- `graph run` 的 `setTermination` 存在 use-after-free：终止条件的 criterion 由调用方持有，改为在图内复制并统一释放
- `graph run` 的用量报告新增 `usage.new_tool_calls`：续跑时已完成节点不会重跑，新增工具调用必须为 0
- 条件路由落地：`evaluate_route` 门按实测值选择下一分支，未选中的分支记录为 `skipped` 且不执行；`NodeResult.skipped` 写入检查点，fan-in 的「进多少出多少」只统计真正执行的分支；`verify` / `approval` 不作为分支候选，始终执行
- CLI 用法与错误文本在退出前 flush：此前写入缓冲 writer 的用法提示会随 `std.process.exit` 丢失
- `websocket.zig` 的 `Frame` 记录 `consumed`，长连接改用直接 socket 读写（`std.Io` 缓冲在长连接上会误报 EOF 并延迟写入）

### Fixed

- `loop_plan` 的输入 schema 声明了 `goal` 但处理函数忽略它（计划标题始终是默认值 `design task`）：改为从输入读取 `goal`，并在计划内持有堆上副本，后续调用保持同一个目标

- `skills/packaging-structural-engineer` 的材料利用率把内容积（升）除以面积（平方米），单位不一致，算出 1280% 这类无意义的数字；改为按实际展开面积除以板材面积，缺板材面积时判为未测量而不是编一个数字

## [0.1.1] - 2026-03-28

### Changed

- 语义版本与 Web Agent 控制台对齐为 0.1.1；宿主支持删除项目与会话跨项目移动；侧栏三栏布局与消息气泡角标操作等（详见 `web/` 变更）。

## [0.2.0] - 2026-03-24

### Added

- CLI：`config validate`；`working show|set`；`fact add`；`serve`（仅 `127.0.0.1`，`GET /health`、`/store`、`/status`，`POST /evolve`）
- 对默认 `store` 路径使用 `store.json.lock` 咨询锁（与 CLI 写路径一致）
- 文档：`docs/cli-exit-codes.md`、`docs/embedding.md`、`docs/roadmap.md`；`testdata/minimal_store_v1.json`；`tests/cli_smoke.sh`；`zig build fmt`
- CI：`.github/workflows/cuteclaw.yml`（Zig 测试 + fmt + 冒烟 + `web` 构建）
- Web：`PUT /api/config` 写入前调用 `cuteclaw config validate`（临时文件 + `CUTECLAW_CONFIG`）

### Changed

- `status` 在无法加载 store 时以退出码 2 失败；`import` JSON 解析失败时退出码 2 并提示 `docs/format.md`
- 帮助文本补充退出码说明
