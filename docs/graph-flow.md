# Graph Flow / Graph Loop（设计过程执行模型）

CuteClaw 的设计过程不靠「模型自己判断够不够」，而是先把工作建成**可审阅的依赖图**，再按层执行。规划权在 Zig 侧：插件只提供能力，图决定什么先跑、什么可以 fan-out、什么必须停在人工审批门前。

技能目录（`src/graph/skills.zig`）来自 `reports/plan-3.md` 的 8 个工程 Skills，加上从 GitHub 上大量筛选的真实 PCB / CAD / 包装工程 Agent Skills（按 star 与工程实用性），共 **54 项**。

## 两条原则

1. **箭头只在工作真的流过去时才成立。** 上游既不产出 artifact、下游也没有读取 `node.<id>.`，这条边就只是叙述上的先后（narration edge），不构成执行约束，执行前必须删除。
2. **工作形状决定拓扑。** 只有真正独立的任务对才值得 fan-out；串行工作排成图、加团队，只会增加协调成本（Google DeepMind × MIT「Towards a Science of Scaling Agent Systems」的停止规则：可拆分的任务上团队约赢 80%，串行工作上每一种团队配置都会输）。

## 模块

| 路径 | 职责 |
|------|------|
| `src/graph/graph.zig` | 图模型：节点、终止条件、分层（Kahn）、隐藏边、叙述边、工作形状判定 |
| `src/graph/state.zig` | 结构化执行记录：已完成节点的结果保留为记录，不从聊天历史里重新发现；检查点与恢复 |
| `src/graph/gates.zig` | 硬门与对抗性审查：终止条件、measured-only、fan-in 完整性、变换前必须标定、不可逆动作前必须有审批祖先 |
| `src/graph/executor.zig` | Graph Loop：分层执行 → 每层后局部重规划 → 门失败触发定向重做（有上限）→ 条件路由跳过未选中的分支 → 停在审批门前 |
| `src/graph/skills.zig` | 从 GitHub 上真实 PCB / CAD / 包装工程 skill 提炼的图模板（46 项） |
| `src/graph/tools.zig` | 注册给模型的工具面，与 Agent、插件共用同一入口和权限检查 |
| `src/cli_graph.zig` | CLI 子命令：`skills` / `plan` / `run` / `gate` / `checkpoint` |

## 工具面

`graph_skills`、`graph_plan`、`graph_run`、`graph_gate`、`graph_checkpoint`。

## 不可协商的规则

- 每个技能必须有**可验证的二元终止条件**和代码内的迭代上限；没有退出条件就不许开环。
- `verify` 节点必须从声明的源依赖**重新推导**，不能读上游的合成结论（不能依赖 fan-in 自己汇总的结果）。
- `gate` 必须有依赖：门不能悬空自确认。
- 含 `transform` 能力的 work 节点必须有 `calibrate` 依赖：先校验工具，再校验结果。
- fan-in 必须进多少出多少；超过批大小宁可多跑一轮，不能静默丢条目。
- 不可逆动作（下单、发文件、落库）必须有传递性的审批祖先。
- 条件路由：下一层跑什么必须由实测值决定（`evaluate_route`）。未被路由选中的分支不执行，也不计入 fan-in 的「进多少出多少」；`verify` / `approval` 不属于分支候选，必须始终执行。
- 推断值（`measured=false`）不能通过 measured-only 硬门。

## plan-3 的映射（五类工具 → 图技能）

`reports/plan-3.md` 把 AI for PCB & CAD Engineering 分成五类工具，并给出 8 个可复用的工程 Skills。这里的取舍是：**工具负责生成，图负责判定**。plan-3 的提醒直接构成图的规则——「实际执行仍需要验证尺寸、公差、电气安全和制造约束，不能仅凭 AI 输出直接量产」，所以每个技能都必须有可验证的终止条件，结论必须来自实测，而不是模型自认为完成。

| plan-3 的工具类别 | 在图里的角色 | 对应技能 |
|------|------|------|
| PCB 电子工程（Flux / CELUS / KiCad / Altium） | 生成候选方案，规则检查落在门上 | `pcb-design-assistant`, `bom-component-selector`, `schematic-readability`, `footprint-symbol-audit`, `signal-integrity-review`, `emc-power-review`, `thermal-power-budget`, `pdn-impedance`, `pcb-design-review`, `fabrication-capability-check` |
| 机械 CAD（Autodesk Fusion / CAD 脚本） | 参数化几何 + 装配与干涉 | `parametric-cad-designer`, `ecad-mcad-integration`, `tolerance-stackup`, `mechanical-review`, `model-compare`, `engineering-drawing-gdt`, `parametric-model-rebuild`, `fea-simulation-evidence` |
| 产品外观设计（AI 概念 + CMF） | 概念探索只出建议，可制造性由独立门判定 | `product-cmf-designer`, `printability-check`, `measured-dfam-slicing` |
| 包装结构工程（Arden Impact / EngView） | 展开图与刀模，利用率按实际面积 | `packaging-structural-engineer`, `dieline-export`, `packaging-transport-test` |
| 包装视觉与渲染（Illustrator / Firefly + 3D 预览） | 印前检查必须对到实际刀模 | `packaging-artwork-preflight`, `drawing-set-index`, `eco-packaging-score` |

plan-3 的 8 个 Skills 是任务模板，本身不含执行保障；落成图之后才有终止条件、门与重做上限：

| plan-3 Skill | 图里补了什么 |
|------|------|
| `PCB-Design-Assistant` | 硬/软约束必须先分开并成门；概念不能直接进布局 |
| `BOM-Component-Selector` | 选型必须来自分销商 API 的实测条目；替代料不能凭记忆 |
| `PCB-Design-Review` | 规则必须套到实际几何；`verify` 从源重推导，不能读上游汇总的合成结论 |
| `ECAD-MCAD-Integration` | 装配前必须标定；干涉门必须有依赖 |
| `Parametric-CAD-Designer` | 模型必须由脚本重跑复现；重跑后测不到的尺寸不是发现 |
| `Product-CMF-Designer` | 概念分支不能自评为通过；可制造性由独立门判定 |
| `Packaging-Structural-Engineer` | 刀模必须分层导出；利用率必须由实际面积计算 |
| `Packaging-Artwork-Preflight` | 出血、字体、条码必须逐条对照实际刀模；版面与刀模不匹配判失败 |

检索结论（2026-10 快照）：纯工程计算类 skill（SPICE、热仿真、爬电距离/电气间隙、via stub、ISTA 跌落、条码预飞、瓦楞 ECT 等）在 GitHub 上几乎没有成规模的 agent skill；成规模的是 EDA / CAD 无头自动化与执行治理类 skill。因此 CuteClaw 把工程计算留在 Zig 侧的确定性插件里（阻抗、公差链、PDN、循环经济性、仿真证据），把治理规则落成图。

## 技能目录（54 项）

### 图执行与回路（Graph Flow / Graph Loop）（25 项）

| 技能 | 任务 | 出处 |
|------|------|------|
| `graph-orchestrator` | 把多步设计工作规划成依赖图：区分叙述上的先后与真正的数据依赖 | github.com/VineeTagarwaL-code/graph-engineering, github.com/RobotSe7en/dagent |
| `work-shape-audit` | 先判断工作形状再决定拓扑：只有真正独立的任务才 fan-out，串行工作排成图反而更差 | github.com/VineeTagarwaL-code/graph-engineering, github.com/codejunkie99/graph-engineering |
| `loop-pattern-picker` | 按工作形状选回路模式：只有真正独立的单元才 fan-out | github.com/invincible04/awesome-loop-engineering, github.com/fltman/loop-engineer |
| `graph-runtime-audit` | 审计图运行时实际执行了什么：fan-in 丢条目、门自确认、叙述边未删除都算失败 | github.com/cobusgreyling/graph-engineering, github.com/HM-Li/graph-engineering |
| `durable-state-loop` | 检查点不是完成的证明：它只记录哪些结果已存在、哪些节点还欠着 | github.com/rajivmehtaflex/graph-flow, github.com/Atakan-Emre/skillstate-kit |
| `quality-loop` | 质量回路：先写下什么最重要，再评估、行动、改进 | github.com/qualitymd/quality.md, github.com/blundergoat/goat-flow |
| `spec-loop` | 规格先冻结再开工：完成定义必须是可检查的构建与测试，而不是模型自认为完成 | github.com/songyang0603/ds-spec-loop, github.com/MichelKerkmeester/skilled-agent-harness_spec-driven-loops |
| `task-graph-protocol` | 把一次交付拆成可审阅的任务图：冻结规格、隔离写入边界、独立评审、证据化验收 | github.com/wu736139669/agent-taskgraph-protocol, github.com/Yassatiqi/orqivra |
| `knowledge-graph-pipeline` | 把设计领域的实体与关系建成可查询的知识图：先建模再抽取，先融合再落库 | github.com/codejunkie99/graph-engineering, github.com/npubird/KnowledgeGraphCourse |
| `loop-engineer` | 为自动化设计回路写下可验证的退出条件与硬上限：没有二元退出条件就不许开环 | github.com/fltman/loop-engineer, github.com/maxmilian/loop-engineering |
| `unfoolable-gate` | 完成必须是观察到的事实：模型的声明与观察必须分开记录，声明不能喂给门 | github.com/selmakcby/loop-engineering, github.com/Railly/skills, github.com/haidrrrry/loop-engineering-skills |
| `conditional-routing` | 下一层跑什么必须由上游的实测结果决定；叙述上的先后不是路由 | github.com/rajivmehtaflex/graph-flow, github.com/context4ai/agent-graph, github.com/Thanarak-q/graph-engineering-workflow |
| `fresh-context-batch` | fan-out 必须在干净上下文里执行：读过的东西不能污染下一项判断 | github.com/odedha-dr/skills-vs-subagents, github.com/MouseRider/skills-tsvc, github.com/xing-0803/agent-runtime-safety-auditor |
| `memory-ontology-layer` | 先建本体层再抽取实体：知识必须可查询，不能塞进 prompt 里靠模型回忆 | github.com/mattgierhart/PRD-driven-context-engineering, github.com/npubird/KnowledgeGraphCourse, github.com/affectionatec/agentic-engineering |
| `headless-eda-automation` | 先校验工具再校验结果：无头 EDA 工具必须真的可运行且版本一致，工具自报的通过不算通过 | github.com/michpro/kicad-tools, github.com/AvatarSD/KiSkill, github.com/pantojinho/hermes-kicad-pcb |
| `human-gate-after-every-step` | 不可逆步骤必须停在人工审批门前：门不能由模型自己批准 | github.com/ChengminLi/AI-PCB-layout, github.com/richfrem/agent-plugins-skills, github.com/kumanaya/graph-engineer |
| `skill-provenance-integrity` | 进入执行图的每个技能必须有出处与完整性校验：哈希不匹配或没有出处的技能不能参与判断 | github.com/hbui290/agentic-skill-library, github.com/zot24/zskills, github.com/jeffreytse/grimoire |
| `postcondition-contract` | 工具层必须有类型化契约与后置条件：后置条件失败必须作废该节点的结论，不能只记一条警告 | github.com/wogokoro/Agentic-CAD-Skills, github.com/ldzhouquan/agent-harness-skill, github.com/sneg55/agent-starter |

| `ground-truth-evaluator` | 自进化必须由冻结的未见测试集评估：评估者不能是生成者自己，测试集不能因为跑不过而被改写 | github.com/FishSerrie/skill-evolver, github.com/Sounder25/Foundational-Agent-Skills, github.com/itumor/dsh-plugin-recursive-optimizer |
| `harness2-evolution-loop` | 自进化必须按 Propose→Probe→Compose→Reflect 跑：Probe 必须在冻结的未见任务集上执行，护栏不可被回路改写，提议不能直接落库 | github.com/itumor/dsh-plugin-recursive-optimizer, github.com/google-research/harness2, github.com/sneg55/agent-starter |
| `skill-trigger-test` | 技能是否被触发必须用正例与负例测试：漏触发与误触发都算失败，不能靠模型自觉选择技能 | github.com/netopsengineer/agent-skill-description-optimizer, github.com/greglas75/zuvo, github.com/rodovalhofs/maestro |
| `publish-gate-set` | 交付前必须跑完固定的门集合：任何一项缺失、跳过或被判定「不适用」都判失败 | github.com/belschak/publish-gate, github.com/ltlongtma/solo-sdlc, github.com/dwang-co/ship-team |
| `predicate-router` | 路由规则必须是可对执行状态求值的谓词（字段+运算符+阈值）：求值失败必须回退默认分支并记录 | github.com/Alpha-Park/genpark-conditional-branch-router-state-evaluator-skill, github.com/Alpha-Park/genpark-stateful-agent-dag-node-executor-skill, github.com/CodeByZaigham/LangGraph-Workflows |
| `risk-gated-plan-review` | 高风险计划必须在执行前被独立评审门拦住：评审者必须与生成者隔离，作者不能评审自己的计划 | github.com/PGHQdev/second-opinion, github.com/GoatGit/super-code-review, github.com/ceoguy/ship-skill |
| `state-machine-constrained-execution` | 执行只能走校验过的规格里声明的状态转移：模型临场发明的转移与跳阶段都判失败 | github.com/H20Zhang/workflow-skill, github.com/agent-ix/ix-flow, github.com/Mench-Li/GuardHarness, github.com/zju-CS-yzy/ipd-agent-workflow-skill |

### PCB / 电子工程（13 项）

| 技能 | 任务 | 出处 |
|------|------|------|
| `pcb-design-assistant` | 按产品需求规划电路架构，并区分硬约束与软约束 | github.com/daishuge/pcb-skill, github.com/nickkraakman/skidl-skills |
| `schematic-readability` | 原理图可读性：功能分区、电源树在上方、信号从左到右 | github.com/Ausanx/modular-schematic-layout, github.com/seanrobertwright/lril-kicad-skills |
| `footprint-symbol-audit` | 符号与封装的引脚到焊盘映射必须来自数据手册 | github.com/seanrobertwright/lril-kicad-skills, github.com/AvatarSD/KiSkill |
| `bom-component-selector` | 比较规格、价格、供货与生命周期 | github.com/Zane456/PCB-Agent-Teams, github.com/daishuge/pcb-skill |
| `signal-integrity-review` | 阻抗、回流路径与串扰必须从叠层与实际几何推导，不允许假设叠层或假设参考平面 | github.com/techsd/engineering-agent-skills, github.com/dungnotnull/pcb-design-assistant-agent-skill |
| `emc-power-review` | 电源树、返回路径、热与阻抗：从网表实际走线推导，不允许推断拓扑 | github.com/Seahan1/hardware-agency-agents, github.com/aklofas/kicad-happy |
| `thermal-power-budget` | 功耗预算必须收支平衡：每一瓦都要归到具体器件，并通过可测量的路径散掉 | github.com/johntonye19-sudo/ee-engineer-x, github.com/Seahan1/hardware-agency-agents |
| `printability-check` | 可制造性检查：水密网格、壁厚、悬垂与公差 | github.com/flowful-ai/cad-skill, github.com/heyixuan2/bambu-studio-ai |
| `dfm-dfa-review` | 可制造与可装配判定必须把工艺限值套到实际几何上，而不是看设计意图 | github.com/SPREsxm/claude-pcb-designer, github.com/almightyshui/Mechanical-AI-Skill |
| `pcb-design-review` | 电气规则、布局与可制造性审查 | github.com/aklofas/kicad-happy, github.com/ChengminLi/AI-PCB-layout |
| `production-release` | 量产文件包：Gerber、钻孔、钢网/BOM、拼板与下单前检查 | github.com/hellofredlam/pcb-gerber, github.com/John-owo/pcb-agent-workflow |
| `pdn-impedance` | 目标阻抗必须从实测去耦网络与回路电感推导；载流宽度按实测电流与温升反推 | github.com/dungnotnull/pcb-design-assistant-agent-skill, github.com/techsd/engineering-agent-skills, github.com/ChengminLi/AI-PCB-layout |
| `fabrication-capability-check` | 设计规则必须与工厂公布能力逐项对照；对照不上的规则只能算未验证 | github.com/SPREsxm/claude-pcb-designer, github.com/sunzhejian/hardware-design-to-manufacturing-skill, github.com/mash/jlcpcb-skills |

### CAD / 机械与产品（11 项）

| 技能 | 任务 | 出处 |
|------|------|------|
| `parametric-cad-designer` | 按参数生成可修改的机械模型 | github.com/forgent3d/forgent3d-skills, github.com/alchaincyf/huashu-cad |
| `ecad-mcad-integration` | PCB 与外壳、连接器、安装结构协同 | github.com/alchaincyf/huashu-cad, github.com/forgent3d/forgent3d-skills |
| `tolerance-stackup` | 公差链必须按最坏情况从实测尺寸累加 | github.com/Eklavya-San/CTQ-extraction, github.com/almightyshui/Mechanical-AI-Skill |
| `mechanical-review` | CAD / FEA / DFM / DFA / 装配分析，按可制造性判定 | github.com/almightyshui/Mechanical-AI-Skill |
| `model-compare` | 把生成的 CAD 模型与基准模型做网格相似度比对，而不是只看脚本写法 | github.com/rawwerks/VibeCAD, github.com/forgent3d/forgent3d-skills |
| `product-cmf-designer` | 探索外观、材料、颜色与表面工艺，并检查是否可制造 | plan-3 skill set + github.com/almightyshui/Mechanical-AI-Skill |
| `engineering-drawing-gdt` | 特征控制框必须逐字保留公差与基准，并与模型实测尺寸对照；凭视觉判断的公差不算标注 | github.com/Eklavya-San/CTQ-extraction, github.com/CavanJB/openclaw-pdf-to-cad-agent-skill, github.com/MeltFlexDevs/techdrawai-skills |
| `parametric-model-rebuild` | 参数化模型必须由脚本重跑复现：重跑后测不到的尺寸不是发现，超差必须报为问题 | github.com/Chocksy/fusion-agent-kit, github.com/forgent3d/forgent3d-skills |
| `drawing-set-index` | 工程图成套性：图框、标题栏、修订记录与图纸索引逐张核对；索引里的图必须在文件里真实存在 | github.com/capskov/luna-cad-sheet-layout, github.com/Eklavya-San/CTQ-extraction, github.com/MeltFlexDevs/techdrawai-skills |
| `measured-dfam-slicing` | 可打印性必须来自实际切片输出（层数、材料体积、支撑面积），不能靠目测模型外观 | github.com/Silexperience210/hermes-3d-construction, github.com/heyixuan2/bambu-studio-ai |

| `fea-simulation-evidence` | 仿真结果必须由可复现的求解运行产生：网格、边界条件与材料必须记录，凭印象的应力或温度不算验证 | github.com/harshavarthan6767/openmechanical, github.com/k-telux/OpticalModeler, github.com/evnchn-agentic/agentic-3d-modeling |

### 包装工程（5 项）

| 技能 | 任务 | 出处 |
|------|------|------|
| `packaging-structural-engineer` | 盒型、内衬、展开图与刀模 | plan-3 skill set（Arden Impact / EngView 工作流） |
| `dieline-export` | 刀模文件必须分层导出：Cut / Crease / Perforation 不能合并成一层，否则无法模切 | github.com/stoneproof-tech/PackagingWorkbench, github.com/sbarrak/packbox |
| `packaging-artwork-preflight` | 印刷文件检查：出血、字体、条码、标识与版面与实际包装的匹配 | plan-3 skill set（Illustrator 印前流程） |
| `packaging-transport-test` | 跌落与堆码必须按实际装载质量与公布的测试方法计算；没有跑过测试程序不能声称通过 | github.com/dungnotnull/packaging-design-advisor-agent-skill, github.com/stoneproof-tech/PackagingWorkbench, github.com/sbarrak/packbox |
| `eco-packaging-score` | 循环经济性评分必须按实际材料成分与装载质量计算：复合材质按不可回收处理，推断的材料属性不计入 | github.com/dungnotnull/eco-packaging-design-agent-skill, github.com/dungnotnull/packaging-design-advisor-agent-skill |

## GitHub 来源（筛选依据）

只收录真正能参与工程建模、验证与出文件的仓库；纯概念生成类工具不计入。star 数为 2026-10 检索时的快照。

**PCB / 电子工程**

| 仓库 | star | 借鉴点 |
|------|------|--------|
| aklofas/kicad-happy | 1514 | 原理图/PCB/Gerber 审查：电源树、子电路、ESD、无源网络、EMC 预合规、量产就绪 |
| zhoushoujianwork/easyeda-agent | 837 | 从需求到原理图与 BOM 的 agent 工作流 |
| daishuge/pcb-skill | 160 | 概念→原理图→选型→布局→验证→下单的门；实测而非推断；先校验工具再校验结果 |
| Zane456/PCB-Agent-Teams | 78 | Phase 0–5 流水线、零幻觉选型（MPN 必须来自分销商 API）、资产落盘前不画图 |
| John-owo/pcb-agent-workflow | 34 | 流程文件、项目模板、生产稿比对脚本 |
| Seahan1/hardware-agency-agents | 28 | 硬件工程技能库：PCB、嵌入式、电源、EMC、验证 |
| ChengminLi/AI-PCB-layout | 28 | 功率电子 PCB，每一步后都有人工评审门 |
| Milind220/Ki-Stack | 23 | 深度 KiCad 技能 |
| nickkraakman/skidl-skills | 23 | SKiDL：架构→选型→代码→验证 |
| SPREsxm/claude-pcb-designer | 9 | 确定性计算、DFM、制造放行 |
| IxTechCrypto/kicad-skills | 7 | 生产级规则集与自动化脚本 |
| luckiday/vibe-hardware | 7 | 从自然语言到固件、PCB、外壳与下单 |
| AvatarSD/KiSkill | 6 | 无头 Python 引擎：编辑、验证、评审、制造导出 |
| xutianq999/pcb-design-skill | 5 | 全流程：原理图→摆放→布线→SI/PI→DRC→制造导出 |
| dungnotnull/pcb-design-assistant-agent-skill | 7 | 按 IPC 标准与数据手册给摆放/布线/SI/PI/EMC 打分 |
| michpro/kicad-tools | 3 | CLI 自动化：分析、验证、修复、制造导出 |
| techsd/engineering-agent-skills | 4 | 工程计算与审查规则集 |
| Ausanx/modular-schematic-layout | 3 | 模块化原理图布局 |
| wenqiiizwq-creator/Autonomous-Schematic-Generation | 3 | 结构化电路表示、功能布局与避障布线、原生 ERC/网表/几何验证 |
| seanrobertwright/lril-kicad-skills | 1 | 先访谈再验证：符号与封装设计 |
| studio-edul/pcb-layout-skill | 1 | 确定性摆放检查、电源路径计算、布线后审计、Gerber 级网表回读 |
| 1999AZZAR/pcb-skill | 1 | kicad-cli 无头自动化 + DRC + 制造导出 |
| mash/jlcpcb-skills | 3 | 制造能力限值与下单前检查 |
| ratemypcb/ratemypcb | 0 | 可制造性打分与问题清单 |
| pantojinho/hermes-kicad-pcb | 2 | 无头 pcbnew Python + kicad-cli + Freerouting：先校验工具再校验结果 |
| Yuna-Celisse/kicad-pcb-skills | 1 | 7 个技能 + 确定性工具包（intent/DRU/gate/calc/analysis）+ stdio MCP |
| yymqd/kicad-pcb-agent-skills | 0 | 三条管线的阶段切换工作流（kicad-cli / MCP / kcaa） |
| sunzhejian/hardware-design-to-manufacturing-skill | 0 | 证据化审查与制造交接：规则必须与工厂能力对照 |
| saikhamhein/agent-skills | 0 | 电子设计 + 机械集成 + 制造流程的可复用技能 |
| A-Magpie/PCBsight | 1 | Altium `.PcbDoc` 解析与审查：文件必须真的可解析才能出结论 |

**CAD / 机械与产品**

| 仓库 | star | 借鉴点 |
|------|------|--------|
| wzyn20051216/solidworks-automation-skill | 1506 | 可靠的 agent 桌面 CAD 自动化 + MCP |
| flowful-ai/cad-skill | 694 | CAD 建模与导出技能 |
| heyixuan2/bambu-studio-ai | 238 | 可打印性检查与切片前门 |
| k-telux/OpticalModeler | 137 | 证据门控（evidence-gated）：可审计的物理模型 |
| rawwerks/VibeCAD | 123 | 网格相似度比对（IoU/Dice），而不是只看脚本写法 |
| delancy827/cad-skills | 94 | AutoCAD 自动化技能包 |
| ReshefElisha/jarvis-onshape-mcp | 175 | 参数模型与装配检查 |
| NeonGlay/inventor-mcp | 47 | 参数化建模驱动 |
| Milkdomeda/ai-mechanical-3dcad-design-agent | 48 | 记录并学习自己的设计技能 |
| almightyshui/Mechanical-AI-Skill | 30 | CAD / FEA / DFM / DFA / 装配审查 |
| beiming183-cloud/AutoCAD-skills | 19 | 国标机械 CAD：严格 DRC、装配与产品安全门 |
| MakeItEzzz555/Gridline | 18 | 工程图与尺寸可测量性 |
| Portauw/caddie | 13 | 可编辑 CAD 输出 |
| alchaincyf/huashu-cad | 12 | 自然语言出可编辑 CAD（DXF/STEP），自动干涉与啮合校验 |
| forgent3d/forgent3d-skills | 9 | 参数化零件、STEP/STL/3MF 导出与测量 |
| czuryk/SolidworksMCP | 7 | 原生参数模型的构建、检查与导出 |
| Eklavya-San/CTQ-extraction | 4 | 从工程图抽取 CTQ 与 GD&T 特征框，逐字保留公差 |
| MeltFlexDevs/techdrawai-skills | 3 | 照片→工程图→DXF/DWG/3D |
| Chocksy/fusion-agent-kit | 3 | 可重跑的构建脚本 + 技能 |
| wogokoro/Agentic-CAD-Skills | 1 | CAD agent 的工具层：类型化工具与后置条件检查 |
| CavanJB/openclaw-pdf-to-cad-agent-skill | 13 | 工程图 PDF → CAD 交付包：公差与基准必须逐字保留 |
| Anson2251/cad-drawing-to-model-skill | 2 | 2D 工程图（多视图 DWG/DXF/图像）→ 参数化 3D 实体 |
| CSCTACG/creo-dev | 7 | Creo Pro/TOOLKIT 开发技能：完整知识 + 可验证构建 |
| evnchn-agentic/agentic-3d-modeling | 3 | build123d 参数化建模：数值可验证的验证回路 |
| lukeoishi/engineering-agent-skills | 3 | 概念 → 参数化 CAD → 可验证导出，多 agent 分工 |
| evgeniyzakharow-design/thermoforming-dfm | 0 | 工艺限值套到实际几何：拔模、圆角按局部拉深、深度按工艺上限 |
| alessandrobonomi00/cad-mechanical-designer-skill | 1 | 设计意图与可制造性指南：参数化建模 + 制造约束 |
| Altern92/openscad-cad-skills | 0 | 唯一机器可验证的运动装配（moving-assembly）设置 |
| capskov/luna-cad-sheet-layout | 0 | 工程图成套性：图框、标题栏与图纸索引逐张核对 |
| Silexperience210/hermes-3d-construction | 0 | 端到端可打印：Blender CAD → 实测 DfAM → 无头切片 → 打印机 |
| hughminhphan/agentic-hardware-stack | 2 | 机电协同：Fusion 360 MCP + KiCad + 实测装配 |
| duding-engicool/skill-tolerance-stackup | 0 | 公差链：最坏情况与 RSS，定位超差风险 |
| LucasOsorio1/tolerance-stackup | 0 | 逐件偏差叠加：worst case / RSS / mean-shift |
| BenCaunt/SynthCAD | 17 | 让编码 agent 可驱动 CAD：脚本化建模与可复现输出 |
| harshavarthan6767/openmechanical | 0 | 可复现的 CadQuery / Gmsh / CalculiX 求解：仿真必须由实际求解运行产生 |
| makepartsnow/skills | 0 | 从 CAD 文件到加工报价与下单：制造交接按实际文件判定 |

**Graph Flow / Graph Loop**

| 仓库 | star | 借鉴点 |
|------|------|--------|
| npubird/KnowledgeGraphCourse | 4485 | 知识图构建阶段划分 |
| codejunkie99/graph-engineering | 551 | 九段知识图流水线：先建模再抽取、先融合再落库、每段都要验证 |
| deerwork-ai/deer-workflow | 551 | 工作流编排与可审阅计划 |
| invincible04/awesome-loop-engineering | 66 | 五种回路模式与嵌套；停止规则必须是二元检查 |
| osovv/grace-marketplace | 254 | 契约驱动：先定义契约再执行 |
| sneg55/agent-starter | 74 | 工程化模板与技能引导 |
| cobusgreyling/graph-engineering | 9 | 运行时审计与分层执行 |
| HM-Li/graph-engineering | 5 | 依赖图与隐藏边 |
| wu736139669/agent-taskgraph-protocol | 4 | 规格冻结、持久角色、隔离写入边界、独立评审、证据化交付 |
| Yassatiqi/orqivra | 3 | 任务图与验收 |
| fltman/loop-engineer | 37 | 有护栏的回路：可验证退出条件、硬迭代上限、代码内预算上限、独立评审者 |
| maxmilian/loop-engineering | 29 | 回路设计与评审 |
| qualitymd/quality.md | 33 | 质量回路的可执行格式：定义最重要的、评估、行动、持续改进 |
| blundergoat/goat-flow | 33 | 执行回路 + 学习回路 |
| stellarlinkco/skills | 27 | 长时执行、高召回评审、可度量的自我改进回路 |
| songyang0603/ds-spec-loop | 39 | 仓库内规格编程（DSH 工程模式） |
| MichelKerkmeester/skilled-agent-harness_spec-driven-loops | 38 | 规格驱动的回路 |
| valzav/valcraft | 22 | 规格与验证 |
| smixs/disruptor-skills | 20 | 拆分与并行 |
| ouob-tw/LoopAgentTeams | 20 | 多 agent 回路 |
| nesquikm/dev-process-toolkit | 9 | 流程工具与检查点 |
| mdayan8/everything-about-loop-engineering | 18 | 回路模式参考与模板 |
| shaal/shipyard | 3 | 交付与验收门 |
| RobotSe7en/dagent | 7 | 动态 DAG：可审阅计划、每层后局部重规划、检查点续跑 |
| rajivmehtaflex/graph-flow | 0 | 持久化、有状态的图协调：并行、条件路由、有界 verify/repair 回路、重启恢复 |
| Atakan-Emre/skillstate-kit | 0 | 技能状态与跨进程续跑 |
| KevinZhangNothing/dsh-task-graph | 2 | DSH 插件视角的任务图与运行状态（含重试） |
| marlingod/graph-engineering-kit | 0 | 图执行工具集 |
| kexinjinnn/graph-engineering | 0 | 图规划参考 |
| VineeTagarwaL-code/graph-engineering | 8 | 依赖图规划：fan-out / 分层 fan-in / 验证回环 / 人工审批门 |
| gaasher/Agent-Loop-Skills | 177 | 回路必须先写门：loop until it's better，评审与生成分离 |
| mattgierhart/PRD-driven-context-engineering | 181 | 记忆作为基础设施：先建本体层，再抽取实体 |
| markoblogo/abvx-agent-skills | 16 | 可审阅的能力层：可移植技能、工作流模式、验证门 |
| context4ai/agent-graph | 16 | 图规格与工具链：动态发现上下文、构建可观察的图 |
| selmakcby/loop-engineering | 13 | 不可被模型糊弄的验证门：完成=观察到的事实 |
| Railly/skills | 11 | contract → loop → verify → gate → correct：done means observed |
| LearnPrompt/loop-engineering | 11 | 把模糊愿望写成可验证目标与自运行回路 |
| richfrem/agent-plugins-skills | 7 | 确定性状态机治理：风险分级与不可伪造的门 |
| Thanarak-q/graph-engineering-workflow | 6 | 可移植的 dynamic graph-of-loops 技能 |
| affectionatec/agentic-engineering | 5 | 文档先行：持久记忆、零歧义规格、append-only 决策 |
| haidrrrry/loop-engineering-skills | 4 | 门写在代码之前 + Reflexion 式学习记忆 |
| dungnotnull/Loop-Engineering-Optimizer | 4 | 用验证门避免并行修改冲突 |
| gootf/software-agent-sop | 2 | 可执行图：22 节点 33 边、CI 可跑的校验器、可续跑 |
| MTEnt/special-skills | 2 | 校验过的工作流图、回路上限、回执（receipts） |
| xing-0803/agent-runtime-safety-auditor | 2 | 上下文隔离、状态机、HITL、幂等性 |
| odedha-dr/skills-vs-subagents | 1 | 基准对比：上下文注入 vs 上下文隔离 |
| MouseRider/skills-tsvc | 1 | Topic-Scoped Virtual Context：按主题隔离的持久上下文 |
| cjz-wr/agent-engineering-workflow | 1 | 状态机、风险分级、影响分析与安全增量修改 |
| kumanaya/graph-engineer | 0 | 会失败的回路 + 决定跑什么的图 + 一个人工门 |
| CodeByZaigham/LangGraph-Workflows | 2 | 顺序 / 并行 / 条件 / 迭代 / 人工在环的图形状（条件路由） |
| Gandharv-Gupta/AgentMesh.Ai | 1 | 图状多 agent 平台：动态工具、状态与可视化 |
| hbui290/agentic-skill-library | 1 | 按需技能库：出处（provenance）、完整性校验与安全信号 |
| zot24/zskills | 2 | 声明式技能包管理：技能、插件与 MCP 服务器单一清单 |
| jeffreytse/grimoire | 33 | 技能包管理器：跨 26 个领域的技能与最佳实践 |
| ldzhouquan/agent-harness-skill | 10 | Harness Engineering 的系统化实现：稳定、可控、可验证的执行环境 |
| sxivansx/loop-engineering | 10 | 自运行回路：发现工作、验证、再决定下一步 |
| KhaiTrang1995/agentic-awesome-kits | 10 | 可复用的回路套件：每种模式都带可核对的完成定义 |
| Mark393295827/third-brain-v7-skills | 141 | agent wiki + 工程技能：先建知识层再执行 |
| sneg55/agent-starter | 74 | 工程化模板与技能引导：契约、后置条件与可验证环境 |
| Cristallin2006/ghidra-skill-for-dsh | 11 | DSH 插件形态的无头守护进程 + 可验证技能（DSH 兼容参考） |

| Alpha-Park/genpark-stateful-agent-dag-node-executor-skill | 9 | 有状态的 DAG 节点执行器：节点从持久状态读输入、写回自己的字段 |
| Alpha-Park/genpark-conditional-branch-router-state-evaluator-skill | 7 | 对状态字典求值的谓词路由：分支由规则决定，不是措辞 |
| FishSerrie/skill-evolver | 20 | 自进化必须由 ground-truth 评估驱动：评估集固定且独立于生成者 |
| Sounder25/Foundational-Agent-Skills | 29 | 确定性执行与 100% 测试过的安全门 |
| belschak/publish-gate | 1 | 发布前的固定门集合：任何一项缺失或跳过都判失败 |
| PGHQdev/second-opinion | 1 | 高风险计划执行前的独立评审门与风险路由 |
| netopsengineer/agent-skill-description-optimizer | 2 | 触发靠描述匹配：必须用正例与负例测试 |
| itumor/dsh-plugin-recursive-optimizer | 0 | DSH 插件形态的 Propose→Probe→Compose→Reflect 回路（DSH 兼容参考） |
| H20Zhang/workflow-skill | 0 | 由校验过的规格约束的有限状态机执行 |
| agent-ix/ix-flow | 1 | 阶段状态机 + 人工门，打包成 skill |
| Mench-Li/GuardHarness | 1 | 计划驱动、状态治理的执行流 |
| rodovalhofs/maestro | 2 | BM25 检索路由与可编辑的 subagent 图 |
| ceoguy/ship-skill | 1 | 逐项构建 → 对抗评审直到干净（有上限） |

**包装工程**

| 仓库 | star | 借鉴点 |
|------|------|--------|
| sbarrak/packbox | 4 | 参数化盒型与展开尺寸 |
| stoneproof-tech/PackagingWorkbench | 3 | FEFCO 参数化盒型与刀模：Cut / Crease / Perforation 分层导出 DXF |
| wtgjx/design-dieline-packaging-skill | 0 | 刀模技能与出血/利用率检查 |
| dungnotnull/packaging-design-advisor-agent-skill | 4 | 按包装材料科学与实际装载质量评估，而不是凭经验 |
| dungnotnull/eco-packaging-design-agent-skill | 4 | 循环经济性：按实际材料成分计算可回收率、再生含量与单一材料占比 |
| dungnotnull/water-rescue-drone-design-agent-skill | 5 | 产品级设计+测试引擎：评分必须由实际参数计算 |

## 五种回路模式

`headless while-loop`（无人值守）、`evaluator-optimizer`（生成与评审分离）、`meta / prompt-refine`（改提示词而不是改产物）、`orchestrator fan-out`（编排器拆分）、`scheduled / triggered`（定时或事件触发）。每一种都必须有可验证退出条件与硬上限；`loop-pattern-picker` 按工作形状选择模式，`graph-runtime-audit` 审计运行时实际执行了什么。每种模式在目录里都有对应技能：headless while-loop → `loop-engineer` / `unfoolable-gate`；evaluator-optimizer → `ground-truth-evaluator` / `quality-loop`；meta / prompt-refine → `skill-trigger-test`；orchestrator fan-out → `graph-orchestrator` / `work-shape-audit` / `fresh-context-batch`；scheduled / triggered → `state-machine-constrained-execution` / `spec-loop`。

## 检查点与续跑

`graph run` 结束后把执行记录写入检查点（内存 + `CUTECLAW_CHECKPOINT_DIR`，或 `--checkpoint-dir`）。检查点包含两部分：

- `results`：已完成节点的结果（结构化记录，不从聊天历史里重新发现）；
- `pending`：还欠哪些节点。

**检查点不是完成的证明**，它只说明哪些结果已存在、哪些节点还欠着。`graph run --resume` 从检查点恢复：已完成的节点不会重跑（`usage.new_tool_calls == 0`），`graph checkpoint` 在没有内存记录时回退到文件，再回退到技能契约。

## 命令示例

```bash
# 技能目录
zig build run -- graph skills

# 构图：先看工作形状，再决定要不要 fan-out
zig build run -- graph plan pcb-design-review
zig build run -- graph plan work-shape-audit
zig build run -- graph plan signal-integrity-review

# 执行：停在人工审批门前，检查点留在工作区可续跑
zig build run -- graph run graph-orchestrator
zig build run -- graph run pcb-design-review demo --max-iterations 2 \
  --measurements '[{"kind":"drc_errors","value":0,"ref":"demo","measured":true}]'
zig build run -- graph run durable-state-loop demo --resume

# 硬门：推断值不能通过
zig build run -- graph gate --measurements '[{"kind":"drc_errors","value":0,"ref":"board","measured":false}]'

# 检查点：还欠哪些节点
zig build run -- graph checkpoint graph-orchestrator
```

对应脚本：`tests/graph.sh`（`make graph`，已并入 `make check`）。

## Cordis 插件

插件只提供能力，不拥有调度权——真正的执行计划仍由 Zig 侧的图执行器决定。见 [dsh-plugins.md](dsh-plugins.md)。

| 插件 | 工具 | 能力 |
|------|------|------|
| `skills/graph-orchestrator` | `audit` | 真实边 / 叙述边 / 分层 / fan-out 建议 |
| `skills/pcb-design-review` | `review` | 只接受可测量结论的审查门 |
| `skills/packaging-structural-engineer` | `dieline` | FEFCO 参数化展开图与刀模分层；利用率按实际展开面积除以板材面积，缺板材面积判为未测量 |
| `skills/signal-integrity-review` | `impedance` | 从叠层与实测几何推导阻抗；近似区间外不编数 |
| `skills/tolerance-stackup` | `stackup` | 最坏情况与 RSS 公差链；推断贡献不计入 |
| `skills/dieline-export` | `layers` | Cut / Crease / Perforation 必须分层，否则判失败 |
| `skills/pdn-impedance` | `pdn` | 从实测去耦与回路电感推导目标阻抗；载流宽度按 IPC-2221 反推 |
| `skills/fabrication-capability-check` | `compare` | 规则与工厂能力逐项对照：缺少能力条目不算通过 |
| `skills/eco-packaging-score` | `score` | 按实际材料成分与装载质量计算循环经济性评分；推断材料不计入 |
| `skills/drawing-set-index` | `index` | 图纸索引与实际图纸逐张核对；标题栏缺项与无日期修订判失败 |
| `skills/parametric-model-rebuild` | `rebuild` | 重跑脚本后的尺寸与目标逐项对照；测不到、推断、超差都判失败 |
| `skills/ground-truth-evaluator` | `evaluate` | 冻结的未见测试集 + 独立评估者；评估者等于生成者判失败 |
| `skills/publish-gate-set` | `gates` | 固定门集合是否真的跑过：未跑、自行豁免、只有声明都判失败 |
| `skills/predicate-router` | `route` | 对执行状态求值的谓词路由；措辞式路由判失败并回退默认分支 |
| `skills/fea-simulation-evidence` | `simulate` | 网格与边界条件必须记录；非求解器结果、未收敛、超屈服判失败 |
