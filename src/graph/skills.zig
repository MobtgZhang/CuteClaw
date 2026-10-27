//! 技能目录：从 GitHub 上真实 PCB / CAD / 包装工程 skill 中提炼的图模板（Graph Flow）。
//!
//! 每个技能 = 阶段图 + 门 + 终止条件。插件只提供能力，不拥有调度权；
//! 调度权在 Zig 侧的图执行器，硬门不可被自进化改写。
//!
//! 出处（GitHub，按 star 与工程实用性筛选）：
//! - aklofas/kicad-happy            原理图/PCB/Gerber 审查：电源树、子电路、ESD、无源网络、认证、量产就绪
//! - daishuge/pcb-skill             概念→原理图→选型→布局→验证→下单的门；实测而非推断；先校验工具再校验结果
//! - Zane456/PCB-Agent-Teams        Phase 0–5 流水线、零幻觉选型（MPN 必须来自分销商 API）、资产落盘前不画图
//! - nickkraakman/skidl-skills      SKiDL：架构→选型→代码→验证
//! - almightyshui/Mechanical-AI-Skill CAD/FEA/DFM/DFA/装配审查
//! - forgent3d/forgent3d-skills     参数化零件、STEP/STL/3MF 导出与测量
//! - alchaincyf/huashu-cad          自然语言出可编辑 CAD（DXF/STEP），自动干涉与啮合校验
//! - VineeTagarwaL-code/graph-engineering  依赖图规划：fan-out / 分层 fan-in / 验证回环 / 人工审批门
//! - RobotSe7en/dagent              动态 DAG：可审阅计划、每层后局部重规划、检查点续跑
//! - codejunkie99/graph-engineering  九段知识图流水线：先建模再抽取、先融合再落库、每段都要验证
//! - wu736139669/agent-taskgraph-protocol  规格冻结、持久角色、隔离写入边界、独立评审、证据化交付
//! - fltman/loop-engineer           有护栏的回路：可验证退出条件、硬迭代上限、代码内预算上限、独立评审者
//! - invincible04/awesome-loop-engineering  五种回路模式与嵌套；停止规则必须是二元检查
//! - stoneproof-tech/PackagingWorkbench  FEFCO 参数化盒型与刀模：Cut / Crease / Perforation 分层导出 DXF
//! - Google DeepMind × MIT「Towards a Science of Scaling Agent Systems」  停止规则：可拆分的任务才值得 fan-out，串行工作用团队反而更差
//!
//! 补充筛选（PCB / CAD / 包装 / 回路，按 star 与工程实用性）：
//! - studio-edul/pcb-layout-skill        确定性摆放检查、电源路径计算、布线后审计、Gerber 级网表回读
//! - haohao-0725/PCB_Layout_with_AGENT_in_KiCAD  人工检查点：预设、是/否决策清单、布线前 1:1 摆放核对、Gerber 回读
//! - 1999AZZAR/pcb-skill                 端到端自主 KiCad：kicad-cli 无头自动化 + DRC + 制造导出
//! - xutianq999/pcb-design-skill         全流程：原理图→摆放→布线→SI/PI→DRC→制造导出
//! - seanrobertwright/lril-kicad-skills  先访谈再验证：符号与封装设计、逐项验证
//! - AvatarSD/KiSkill、michpro/kicad-tools  无头引擎与 CLI：编辑、验证、评审、制造导出
//! - dungnotnull/pcb-design-assistant-agent-skill  按 IPC 标准与数据手册给摆放/布线/SI/PI/EMC 打分
//! - techsd/engineering-agent-skills     工程计算与审查规则集
//! - Eklavya-San/CTQ-extraction          从工程图抽取 CTQ 与 GD&T 特征框，逐字保留公差
//! - wogokoro/Agentic-CAD-Skills         CAD agent 的工具层：类型化工具与后置条件检查
//! - MeltFlexDevs/techdrawai-skills      照片→工程图→DXF/DWG/3D
//! - delancy827/cad-skills、beiming183-cloud/AutoCAD-skills  国标机械 CAD：严格 DRC、装配与产品安全门
//! - k-telux/OpticalModeler              证据门控（evidence-gated）：可审计的物理模型
//! - rajivmehtaflex/graph-flow           持久化、有状态的图协调：并行、条件路由、有界 verify/repair 回路、重启恢复
//! - KevinZhangNothing/dsh-task-graph    DSH 插件视角的任务图与运行状态（含重试）
//! - qualitymd/quality.md、blundergoat/goat-flow、stellarlinkco/skills  质量回路与学习回路的可执行格式
//! - songyang0603/ds-spec-loop、MichelKerkmeester/skilled-agent-harness_spec-driven-loops、strelov1/spec-driven-tdd  规格先冻结、可检查的完成定义
//! - invincible04/awesome-loop-engineering、mdayan8/everything-about-loop-engineering  五种回路模式与嵌套；停止规则必须是二元检查
//! - gaasher/Agent-Loop-Skills、markoblogo/abvx-agent-skills、haidrrrry/loop-engineering-skills  回路必须先写门；完成=观察到的事实
//! - selmakcby/loop-engineering、Railly/skills  不可被模型糊弄的验证门：声明与观察必须分开
//! - context4ai/agent-graph、Thanarak-q/graph-engineering-workflow、gootf/software-agent-sop、kumanaya/graph-engineer  条件路由与可续跑的执行图
//! - odedha-dr/skills-vs-subagents、MouseRider/skills-tsvc、xing-0803/agent-runtime-safety-auditor  上下文隔离：判断不能继承它读过的东西
//! - mattgierhart/PRD-driven-context-engineering、affectionatec/agentic-engineering  记忆作为基础设施：先建本体层再抽取
//! - CavanJB/openclaw-pdf-to-cad-agent-skill、Anson2251/cad-drawing-to-model-skill  工程图→模型：公差与基准必须逐字保留
//! - evgeniyzakharow-design/thermoforming-dfm、alessandrobonomi00/cad-mechanical-designer-skill  工艺限值必须套到实际几何上
//! - dungnotnull/packaging-design-advisor-agent-skill  包装必须按材料科学与实际装载质量计算
//! - sunzhejian/hardware-design-to-manufacturing-skill、John-owo/pcb-agent-workflow  设计规则必须与工厂公布能力逐项对照
//! - pantojinho/hermes-kicad-pcb、yymqd/kicad-pcb-agent-skills、Yuna-Celisse/kicad-pcb-skills  无头 EDA：先校验工具再校验结果
//! - ChengminLi/AI-PCB-layout、richfrem/agent-plugins-skills  每一步后的人工门与风险分级
//! - Chocksy/fusion-agent-kit  参数化模型必须由脚本重跑复现：重跑后与目标尺寸逐项对照
//! - capskov/luna-cad-sheet-layout  工程图成套性：图框、标题栏、修订记录与图纸索引逐张核对
//! - Silexperience210/hermes-3d-construction  可打印性必须来自实际切片输出（层数、材料体积、支撑面积）
//! - dungnotnull/eco-packaging-design-agent-skill  环保评分必须按实际材料成分与装载质量计算
//! - hbui290/agentic-skill-library、zot24/zskills、jeffreytse/grimoire  进入图的技能必须有出处与完整性校验
//! - ldzhouquan/agent-harness-skill、sneg55/agent-starter  工具层契约：类型化输入与后置条件检查
//! - CodeByZaigham/LangGraph-Workflows、Gandharv-Gupta/AgentMesh.Ai  顺序/并行/条件/迭代/人工在环的图形状
//! - Milind220/Ki-Stack、IxTechCrypto/kicad-skills、luckiday/vibe-hardware、hughminhphan/agentic-hardware-stack  机电协同与工厂能力对照
//! - duding-engicool/skill-tolerance-stackup、LucasOsorio1/tolerance-stackup  公差链必须区分最坏情况与 RSS，并定位超差风险
//! - sxivansx/loop-engineering、KhaiTrang1995/agentic-awesome-kits、Mark393295827/third-brain-v7-skills  回路必须先写门与可核对的完成定义
//! - Alpha-Park/genpark-stateful-agent-dag-node-executor-skill、genpark-conditional-branch-router-state-evaluator-skill  有状态 DAG 节点执行器 + 对状态字典求值的谓词路由
//! - FishSerrie/skill-evolver、Sounder25/Foundational-Agent-Skills  自进化必须由冻结的 ground-truth 评估驱动；确定性执行与测试过的安全门
//! - itumor/dsh-plugin-recursive-optimizer（DSH 插件形态）、google-research/harness2  Propose→Probe→Compose→Reflect；护栏不可被自进化改写
//! - belschak/publish-gate、ltlongtma/solo-sdlc、dwang-co/ship-team、ceoguy/ship-skill  交付前必须跑完固定的门集合，不能自行豁免
//! - PGHQdev/second-opinion、GoatGit/super-code-review、xing-0803/agent-runtime-safety-auditor  高风险计划执行前的独立评审门；作者不能评审自己的计划
//! - netopsengineer/agent-skill-description-optimizer、greglas75/zuvo、rodovalhofs/maestro  技能触发靠描述/检索匹配：必须用正例与负例测试
//! - H20Zhang/workflow-skill、agent-ix/ix-flow、Mench-Li/GuardHarness、zju-CS-yzy/ipd-agent-workflow-skill、richfrem/agent-plugins-skills  执行只能走校验过的规格里声明的状态转移
//! - harshavarthan6767/openmechanical、evnchn-agentic/agentic-3d-modeling、BenCaunt/SynthCAD、A-Magpie/PCBsight  仿真与建模必须由可复现的运行产生：网格、边界条件与文件解析都要留证
//! - makepartsnow/skills  制造交接按实际 CAD 文件判定，而不是按设计意图

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const constraints = @import("../design/constraints.zig");
const graph = @import("graph.zig");
const gates = @import("gates.zig");

const Allocator = std.mem.Allocator;

pub const Spec = struct {
    id: []const u8,
    capability: []const u8,
    kind: graph.NodeKind = .work,
    tier: graph.Tier = .standard,
    risk: graph.Risk = .low,
    phase: usize = 0,
    depends_on: []const []const u8 = &.{},
    writes: []const u8 = "",
    rederive: bool = false,
    retry_target: []const u8 = "",
    batch: usize = 0,
    irreversible: bool = false,
    /// fan-out 在干净上下文里执行：读过的东西不能污染下一项判断。
    fresh_context: bool = false,
    /// 0 = 宿主没有 subagent 工具，降级为分批工具调用。
    max_parallel: usize = 0,
};

pub const Skill = struct {
    id: []const u8,
    name: []const u8,
    task: []const u8,
    deliverable: []const u8,
    source: []const u8,
    termination: graph.Termination,
    specs: []const Spec,
};

pub const catalog = [_]Skill{
    .{
        .id = "graph-orchestrator",
        .name = "Graph Orchestrator",
        .task = "把多步设计工作规划成依赖图：区分叙述上的先后与真正的数据依赖",
        .deliverable = "阶段计划 + fan-out/fan-in 分层 + 验证回环 + 人工审批门",
        .source = "github.com/VineeTagarwaL-code/graph-engineering, github.com/RobotSe7en/dagent",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "no unresolved finding may remain; a failed verification feeds a targeted redo of the affected node only" },
        .specs = &.{
            .{ .id = "rubric", .capability = "define_rubric", .phase = 0 },
            .{ .id = "batch_a", .capability = "audit", .kind = .fan_out, .tier = .standard, .phase = 1, .depends_on = &.{"rubric"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "batch_b", .capability = "audit", .kind = .fan_out, .tier = .standard, .phase = 1, .depends_on = &.{"rubric"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "merge", .capability = "consolidate", .kind = .fan_in, .tier = .cheap, .batch = 25, .phase = 2, .depends_on = &.{ "batch_a", "batch_b" }, .retry_target = "batch_a", .writes = "findings" },
            .{ .id = "source", .capability = "read_source", .phase = 2 },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 3, .depends_on = &.{"merge"}, .retry_target = "merge" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 4, .depends_on = &.{ "source", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 5, .depends_on = &.{"gate"} },
            .{ .id = "deliver", .capability = "publish_report", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 6, .depends_on = &.{"approval"}, .writes = "report" },
        },
    },
    .{
        .id = "pcb-design-assistant",
        .name = "PCB Design Assistant",
        .task = "按产品需求规划电路架构，并区分硬约束与软约束",
        .deliverable = "电路框图、原理图草案、已确认的约束集",
        .source = "github.com/daishuge/pcb-skill, github.com/nickkraakman/skidl-skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "every question whose two answers give a different board must be asked before drafting" },
        .specs = &.{
            .{ .id = "requirements", .capability = "parse_requirements", .phase = 0 },
            .{ .id = "constraints", .capability = "split_hard_soft", .kind = .gate, .phase = 1, .depends_on = &.{"requirements"}, .retry_target = "requirements", .writes = "constraints" },
            .{ .id = "architecture", .capability = "block_diagram", .phase = 2, .depends_on = &.{"constraints"}, .writes = "architecture" },
            .{ .id = "schematic", .capability = "draft_schematic", .phase = 3, .depends_on = &.{"architecture"}, .writes = "schematic" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 4, .depends_on = &.{ "requirements", "schematic" }, .retry_target = "schematic" },
        },
    },
    .{
        .id = "bom-component-selector",
        .name = "BOM Component Selector",
        .task = "比较规格、价格、供货与生命周期；型号必须来自分销商 API，不得由模型编造",
        .deliverable = "BOM、替代料清单、价格标注（VERIFIED 或 ESTIMATE）",
        .source = "github.com/Zane456/PCB-Agent-Teams, github.com/daishuge/pcb-skill",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "every MPN comes from a live distributor response; zero stock or no library is dropped" },
        .specs = &.{
            .{ .id = "spec", .capability = "extract_spec", .phase = 0 },
            .{ .id = "lane_digikey", .capability = "distributor_query", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"spec"} },
            .{ .id = "lane_mouser", .capability = "distributor_query", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"spec"} },
            .{ .id = "lane_lcsc", .capability = "distributor_query", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"spec"} },
            .{ .id = "filters", .capability = "hard_filter", .kind = .gate, .phase = 2, .depends_on = &.{ "lane_digikey", "lane_mouser", "lane_lcsc" }, .retry_target = "lane_lcsc", .writes = "shortlist" },
            .{ .id = "bom", .capability = "build_bom", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{"filters"}, .retry_target = "filters", .writes = "bom" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"bom"}, .retry_target = "bom" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "spec", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "pcb-design-review",
        .name = "PCB Design Review",
        .task = "电气规则、布局与可制造性审查；绿板不等于正确",
        .deliverable = "审查报告、问题清单（按严重级别分组）",
        .source = "github.com/aklofas/kicad-happy, github.com/ChengminLi/AI-PCB-layout",
        .termination = .{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "hard DRC violations must be zero, measured from parsed files rather than reported by the EDA" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "parse", .capability = "read_kicad", .phase = 1, .depends_on = &.{"calibrate"}, .writes = "board" },
            .{ .id = "power_tree", .capability = "trace_power_tree", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"parse"} },
            .{ .id = "subcircuits", .capability = "identify_subcircuits", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"parse"} },
            .{ .id = "esd", .capability = "audit_esd", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"parse"} },
            .{ .id = "dfm", .capability = "check_dfm", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"parse"} },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 30, .phase = 3, .depends_on = &.{ "power_tree", "subcircuits", "esd", "dfm" }, .retry_target = "parse", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "parse", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "ecad-mcad-integration",
        .name = "ECAD–MCAD Integration",
        .task = "PCB 与外壳、连接器、安装结构协同；干涉与装配检查",
        .deliverable = "3D 装配、干涉检查报告、安装结构清单",
        .source = "github.com/alchaincyf/huashu-cad, github.com/forgent3d/forgent3d-skills",
        .termination = .{ .kind = .fit_clearance, .limit = 0, .direction = .min, .max_iterations = 4, .criterion = "no negative clearance between board, enclosure cavity and connectors" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "board", .capability = "read_kicad", .phase = 1, .depends_on = &.{"calibrate"}, .writes = "board" },
            .{ .id = "shell", .capability = "read_step", .phase = 1, .depends_on = &.{"calibrate"}, .writes = "enclosure" },
            .{ .id = "assembly", .capability = "apply_transform", .kind = .work, .phase = 2, .depends_on = &.{ "calibrate", "board", "shell" }, .writes = "assembly" },
            .{ .id = "interference", .capability = "interference_check", .kind = .gate, .phase = 3, .depends_on = &.{"assembly"}, .retry_target = "assembly" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 4, .depends_on = &.{ "board", "interference" }, .retry_target = "interference" },
        },
    },
    .{
        .id = "parametric-cad-designer",
        .name = "Parametric CAD Designer",
        .task = "按参数生成可修改的机械模型（卡扣、螺丝柱、散热孔、PCB 安装位）",
        .deliverable = "CAD 模型、工程图、STEP/STL/3MF 导出",
        .source = "github.com/forgent3d/forgent3d-skills, github.com/alchaincyf/huashu-cad",
        .termination = .{ .kind = .enclosure_wall, .limit = 1.2, .direction = .min, .max_iterations = 5, .criterion = "every parameter must be measurable on the model; a dimension that cannot be measured is not a finding" },
        .specs = &.{
            .{ .id = "params", .capability = "read_parameters", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"params"} },
            .{ .id = "model", .capability = "build_model", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "model" },
            .{ .id = "measure", .capability = "apply_transform", .kind = .work, .phase = 3, .depends_on = &.{ "calibrate", "model" } },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"measure"}, .retry_target = "model" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "params", "gate" }, .retry_target = "gate" },
            .{ .id = "export", .capability = "export_step", .kind = .work, .risk = .medium, .phase = 6, .depends_on = &.{"verify"}, .writes = "export" },
        },
    },
    .{
        .id = "product-cmf-designer",
        .name = "Product CMF Designer",
        .task = "探索外观、材料、颜色与表面工艺，并检查是否可制造",
        .deliverable = "外观方案、CMF 规格、可制造性判断",
        .source = "plan-3 skill set + github.com/almightyshui/Mechanical-AI-Skill",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "concept exploration is capped; only manufacturability-checked concepts survive" },
        .specs = &.{
            .{ .id = "brief", .capability = "read_brief", .phase = 0 },
            .{ .id = "concept_a", .capability = "explore_concept", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"brief"} },
            .{ .id = "concept_b", .capability = "explore_concept", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"brief"} },
            .{ .id = "shortlist", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 2, .depends_on = &.{ "concept_a", "concept_b" }, .retry_target = "concept_a", .writes = "concepts" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 3, .depends_on = &.{"shortlist"}, .retry_target = "shortlist" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 4, .depends_on = &.{ "brief", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "packaging-structural-engineer",
        .name = "Packaging Structural Engineer",
        .task = "盒型、内衬、展开图与刀模；折叠关系与材料利用率",
        .deliverable = "Dieline、3D 包装模型、材料利用率与出血检查",
        .source = "plan-3 skill set（Arden Impact / EngView 工作流）",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "dieline must fold without interference and stay inside the material sheet" },
        .specs = &.{
            .{ .id = "product", .capability = "read_product", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"product"} },
            .{ .id = "dieline", .capability = "generate_dieline", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "dieline" },
            .{ .id = "fold", .capability = "apply_transform", .kind = .work, .phase = 3, .depends_on = &.{ "calibrate", "dieline" } },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"fold"}, .retry_target = "dieline" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "product", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 6, .depends_on = &.{"verify"} },
            .{ .id = "handoff", .capability = "export_for_supplier", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 7, .depends_on = &.{"approval"}, .writes = "package_files" },
        },
    },
    .{
        .id = "packaging-artwork-preflight",
        .name = "Packaging Artwork Preflight",
        .task = "印刷文件检查：出血、字体、条码、标识与版面与实际包装的匹配",
        .deliverable = "印前检查报告（按严重级别分组）",
        .source = "plan-3 skill set（Illustrator 印前流程）",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 3, .criterion = "no preflight error may remain; warnings are reported, not silently accepted" },
        .specs = &.{
            .{ .id = "artwork", .capability = "read_artwork", .phase = 0 },
            .{ .id = "bleed", .capability = "check_bleed", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"artwork"} },
            .{ .id = "fonts", .capability = "check_fonts", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"artwork"} },
            .{ .id = "barcode", .capability = "check_barcode", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{"artwork"} },
            .{ .id = "report", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 2, .depends_on = &.{ "bleed", "fonts", "barcode" }, .retry_target = "artwork", .writes = "preflight" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 3, .depends_on = &.{"report"}, .retry_target = "report" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 4, .depends_on = &.{ "artwork", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "production-release",
        .name = "Production Release",
        .task = "量产文件包：Gerber、钻孔、钢网/BOM、拼板与下单前检查",
        .deliverable = "可下单的量产包（Gerber + 钻孔 + 钢网 + 拼板 + 下单清单）",
        .source = "github.com/hellofredlam/pcb-gerber, github.com/John-owo/pcb-agent-workflow, github.com/SPREsxm/claude-pcb-designer",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "the production package must be re-derived from the board, not from an earlier summary" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "board", .capability = "read_kicad", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "board" },
            .{ .id = "gerber", .capability = "generate_gerber", .kind = .work, .phase = 2, .depends_on = &.{"board"}, .writes = "gerber" },
            .{ .id = "drill", .capability = "check_drill", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"gerber"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "paste_bom", .capability = "check_paste_bom", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"gerber"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "panel", .capability = "check_panel", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"gerber"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "package", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "drill", "paste_bom", "panel" }, .retry_target = "gerber", .writes = "package" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"package"}, .retry_target = "package" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "board", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 6, .depends_on = &.{"verify"} },
            .{ .id = "order", .capability = "place_order", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 7, .depends_on = &.{"approval"}, .writes = "order" },
        },
    },
    .{
        .id = "model-compare",
        .name = "Model Compare",
        .task = "把生成的 CAD 模型与基准模型做网格相似度比对，而不是只看脚本写法",
        .deliverable = "IoU / Dice 比对报告与差异清单",
        .source = "github.com/rawwerks/VibeCAD, github.com/forgent3d/forgent3d-skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "shape similarity must be measured on the mesh (IoU/Dice), not asserted from the script" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "gold", .capability = "read_model", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "gold" },
            .{ .id = "generated", .capability = "build_model", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "generated" },
            .{ .id = "watertight", .capability = "check_watertight", .kind = .work, .phase = 2, .depends_on = &.{"generated"}, .writes = "watertight" },
            .{ .id = "iou", .capability = "measure_iou", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"watertight"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "dice", .capability = "measure_dice", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"watertight"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "score", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "iou", "dice" }, .retry_target = "generated", .writes = "score" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"score"}, .retry_target = "score" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "gold", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "printability-check",
        .name = "Printability Check",
        .task = "可制造性检查：水密网格、壁厚、悬垂与公差；严格模式下不通过即失败",
        .deliverable = "可打印性报告（严格模式：非水密网格直接判失败）",
        .source = "github.com/flowful-ai/cad-skill, github.com/heyixuan2/bambu-studio-ai",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "a strict mesh check must pass; a non-watertight mesh fails the run rather than being reported as a warning" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "mesh", .capability = "read_mesh", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "mesh" },
            .{ .id = "wall", .capability = "check_wall", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"mesh"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "overhang", .capability = "check_overhang", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"mesh"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "tolerance", .capability = "check_tolerance", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"mesh"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "report", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "wall", "overhang", "tolerance" }, .retry_target = "mesh", .writes = "printability" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"report"}, .retry_target = "report" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "mesh", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "emc-power-review",
        .name = "EMC & Power Review",
        .task = "电源树、返回路径、热与阻抗：从网表实际走线推导，不允许推断拓扑",
        .deliverable = "EMC / 电源完整性审查报告与整改项",
        .source = "github.com/Seahan1/hardware-agency-agents, github.com/aklofas/kicad-happy",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "power tree and return paths must be traced from the netlist; an inferred topology is not a finding" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "netlist", .capability = "read_netlist", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "netlist" },
            .{ .id = "power_tree", .capability = "trace_power_tree", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "return_path", .capability = "trace_return_path", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "thermal", .capability = "thermal_check", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "impedance", .capability = "impedance_check", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "power_tree", "return_path", "thermal", "impedance" }, .retry_target = "netlist", .writes = "emc_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "netlist", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "mechanical-review",
        .name = "Mechanical Review",
        .task = "CAD / FEA / DFM / DFA / 装配分析，按可制造性判定",
        .deliverable = "机械审查报告与整改清单",
        .source = "github.com/almightyshui/Mechanical-AI-Skill",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "every claim that decides whether work continues must be measured, not inferred" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "model", .capability = "read_model", .phase = 1, .depends_on = &.{"calibrate"}, .writes = "model" },
            .{ .id = "fea", .capability = "fea_check", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"model"} },
            .{ .id = "dfm", .capability = "dfm_check", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"model"} },
            .{ .id = "dfa", .capability = "dfa_check", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"model"} },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "fea", "dfm", "dfa" }, .retry_target = "model", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "model", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "work-shape-audit",
        .name = "Work Shape Audit",
        .task = "先判断工作形状再决定拓扑：只有真正独立的任务才 fan-out，串行工作排成图反而更差",
        .deliverable = "真实依赖图（删除叙述性假边）+ 隐藏边 + 拆分建议与停止规则",
        .source = "github.com/VineeTagarwaL-code/graph-engineering, github.com/codejunkie99/graph-engineering",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "an edge is real only when work flows through it; narration-only ordering must be removed before execution" },
        .specs = &.{
            .{ .id = "inventory", .capability = "enumerate_tasks", .phase = 0, .writes = "tasks" },
            .{ .id = "audit", .capability = "audit_edges", .kind = .work, .phase = 1, .depends_on = &.{"inventory"}, .writes = "edges" },
            .{ .id = "hidden", .capability = "detect_hidden_edges", .kind = .work, .tier = .cheap, .phase = 1, .depends_on = &.{"inventory"}, .writes = "hidden_edges" },
            .{ .id = "fake_edge_gate", .capability = "check_gate", .kind = .gate, .phase = 2, .depends_on = &.{ "audit", "hidden" }, .retry_target = "audit", .writes = "shape" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 3, .depends_on = &.{ "inventory", "fake_edge_gate" }, .retry_target = "fake_edge_gate" },
        },
    },
    .{
        .id = "knowledge-graph-pipeline",
        .name = "Knowledge Graph Pipeline",
        .task = "把设计领域的实体与关系建成可查询的知识图：先建模再抽取，先融合再落库",
        .deliverable = "本体 + 实体/关系/事件 + 质量门报告 + 可服务给 LLM 的图",
        .source = "github.com/codejunkie99/graph-engineering, github.com/npubird/KnowledgeGraphCourse",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "model the domain before extracting and fuse before storing; every stage must be verified against the source documents" },
        .specs = &.{
            .{ .id = "scope", .capability = "scope_domain", .phase = 0 },
            .{ .id = "ontology", .capability = "define_ontology", .phase = 1, .depends_on = &.{"scope"}, .writes = "ontology" },
            .{ .id = "entities", .capability = "extract_entities", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"ontology"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "relations", .capability = "extract_relations", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"ontology"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "events", .capability = "extract_events", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"ontology"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "quality", .capability = "check_gate", .kind = .gate, .phase = 3, .depends_on = &.{ "entities", "relations", "events" }, .retry_target = "entities", .writes = "quality" },
            .{ .id = "fusion", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 4, .depends_on = &.{"quality"}, .retry_target = "quality", .writes = "knowledge_graph" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "ontology", "quality" }, .retry_target = "quality" },
            .{ .id = "serve", .capability = "serve_graph", .kind = .work, .risk = .medium, .phase = 6, .depends_on = &.{"verify"}, .writes = "served_graph" },
        },
    },
    .{
        .id = "task-graph-protocol",
        .name = "Task Graph Protocol",
        .task = "把一次交付拆成可审阅的任务图：冻结规格、隔离写入边界、独立评审、证据化验收",
        .deliverable = "团队章程 + 任务依赖图 + 写入边界 + 验收证据",
        .source = "github.com/wu736139669/agent-taskgraph-protocol, github.com/Yassatiqi/orqivra",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "definition of done must be checkable by build and tests; two workers may not write the same file" },
        .specs = &.{
            .{ .id = "charter", .capability = "define_outcome", .phase = 0, .writes = "outcome" },
            .{ .id = "boundaries", .capability = "check_gate", .kind = .gate, .phase = 1, .depends_on = &.{"charter"}, .retry_target = "charter", .writes = "boundaries" },
            .{ .id = "worker_a", .capability = "build", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"boundaries"}, .fresh_context = true, .max_parallel = 10, .writes = "worker_a" },
            .{ .id = "worker_b", .capability = "build", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"boundaries"}, .fresh_context = true, .max_parallel = 10, .writes = "worker_b" },
            .{ .id = "evidence", .capability = "collect_evidence", .kind = .work, .tier = .cheap, .phase = 3, .depends_on = &.{"boundaries"}, .writes = "evidence" },
            .{ .id = "integrate", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "worker_a", "worker_b", "evidence" }, .retry_target = "worker_a", .writes = "integration" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "charter", "boundaries" }, .retry_target = "boundaries" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 6, .depends_on = &.{"verify"} },
            .{ .id = "deliver", .capability = "publish_delivery", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 7, .depends_on = &.{"approval"}, .writes = "delivery" },
        },
    },
    .{
        .id = "loop-engineer",
        .name = "Loop Engineer",
        .task = "为自动化设计回路写下可验证的退出条件与硬上限：没有二元退出条件就不许开环",
        .deliverable = "回路规格 + 退出检查 + 代码内预算上限 + 独立评审者",
        .source = "github.com/fltman/loop-engineer, github.com/maxmilian/loop-engineering, github.com/invincible04/awesome-loop-engineering",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 8, .criterion = "the loop stops only when a binary exit check passes; a vague objective is not an exit condition and must be rejected before any side effect" },
        .specs = &.{
            .{ .id = "objective", .capability = "define_objective", .phase = 0, .writes = "objective" },
            .{ .id = "exit_gate", .capability = "check_gate", .kind = .gate, .phase = 1, .depends_on = &.{"objective"}, .retry_target = "objective", .writes = "exit_check" },
            .{ .id = "generate", .capability = "generate_candidate", .kind = .work, .phase = 2, .depends_on = &.{"exit_gate"}, .writes = "candidate" },
            .{ .id = "critic", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 3, .depends_on = &.{ "objective", "exit_gate" }, .retry_target = "generate" },
            .{ .id = "budget_gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"critic"}, .retry_target = "generate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 5, .depends_on = &.{"budget_gate"} },
            .{ .id = "run_loop", .capability = "run_loop", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 6, .depends_on = &.{"approval"}, .writes = "loop_run" },
        },
    },
    .{
        .id = "schematic-readability",
        .name = "Schematic Readability",
        .task = "原理图可读性：功能分区、电源树在上方、信号从左到右；ERC 必须从解析出的网表实测",
        .deliverable = "分区后的原理图 + ERC 报告（实测，非工具自报）",
        .source = "github.com/Ausanx/modular-schematic-layout, github.com/seanrobertwright/lril-kicad-skills, github.com/wenqiiizwq-creator/Autonomous-Schematic-Generation",
        .termination = .{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "ERC must be zero measured from the parsed netlist; a schematic that only looks tidy is not a finding" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "netlist", .capability = "read_netlist", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "netlist" },
            .{ .id = "blocks", .capability = "check_functional_blocks", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "flow", .capability = "check_signal_flow", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "power_order", .capability = "check_power_order", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"netlist"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "blocks", "flow", "power_order" }, .retry_target = "netlist", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "netlist", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "footprint-symbol-audit",
        .name = "Footprint & Symbol Audit",
        .task = "符号与封装的引脚到焊盘映射必须来自数据手册；courtyard 与安装间隙必须可测量",
        .deliverable = "引脚映射表、封装差异清单、courtyard 冲突清单",
        .source = "github.com/seanrobertwright/lril-kicad-skills, github.com/AvatarSD/KiSkill, github.com/michpro/kicad-tools",
        .termination = .{ .kind = .courtyard_gap, .limit = 0, .direction = .min, .max_iterations = 4, .criterion = "pin-to-pad mapping must be traceable to the datasheet; a symbol that cannot be traced is not a finding" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "datasheet", .capability = "read_datasheet", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "datasheet" },
            .{ .id = "library", .capability = "read_symbol_library", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "library" },
            .{ .id = "pin_map", .capability = "check_pin_map", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{ "datasheet", "library" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "courtyard", .capability = "check_courtyard", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"library"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "pin_map", "courtyard" }, .retry_target = "datasheet", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "datasheet", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "signal-integrity-review",
        .name = "Signal Integrity Review",
        .task = "阻抗、回流路径与串扰必须从叠层与实际几何推导，不允许假设叠层或假设参考平面",
        .deliverable = "阻抗/回流/串扰审查报告与整改项",
        .source = "github.com/techsd/engineering-agent-skills, github.com/dungnotnull/pcb-design-assistant-agent-skill, github.com/IxTechCrypto/kicad-skills",
        .termination = .{ .kind = .trace_width, .limit = 0.15, .direction = .min, .max_iterations = 4, .criterion = "impedance must be derived from the stackup and measured geometry; an assumed stackup is not a finding" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "stackup", .capability = "read_stackup", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "stackup" },
            .{ .id = "geometry", .capability = "read_geometry", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "geometry" },
            .{ .id = "impedance", .capability = "measure_impedance", .kind = .fan_out, .tier = .strong, .phase = 2, .depends_on = &.{ "stackup", "geometry" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "return_path", .capability = "trace_return_path", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"geometry"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "crosstalk", .capability = "check_crosstalk", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"geometry"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "impedance", "return_path", "crosstalk" }, .retry_target = "geometry", .writes = "si_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "stackup", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "thermal-power-budget",
        .name = "Thermal & Power Budget",
        .task = "功耗预算必须收支平衡：每一瓦都要归到具体器件，并通过可测量的路径散掉",
        .deliverable = "功耗预算表、热路径与降额检查报告",
        .source = "github.com/johntonye19-sudo/ee-engineer-x, github.com/Seahan1/hardware-agency-agents",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "the power budget must balance: every watt is attributed to a component and dissipated through a measured path" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "budget", .capability = "read_power_budget", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "budget" },
            .{ .id = "dissipation", .capability = "estimate_dissipation", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"budget"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "thermal_path", .capability = "check_thermal_path", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"budget"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "derating", .capability = "check_derating", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"budget"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "dissipation", "thermal_path", "derating" }, .retry_target = "budget", .writes = "thermal_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "budget", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "tolerance-stackup",
        .name = "Tolerance Stackup",
        .task = "公差链必须按最坏情况从实测尺寸累加；只按名义值算的公差链不算结论",
        .deliverable = "最坏情况公差链、GD&T/CTQ 特征框、配合间隙判定",
        .source = "github.com/Eklavya-San/CTQ-extraction, github.com/almightyshui/Mechanical-AI-Skill, github.com/beiming183-cloud/AutoCAD-skills",
        .termination = .{ .kind = .fit_clearance, .limit = 0, .direction = .min, .max_iterations = 4, .criterion = "the tolerance chain must be summed worst-case from measured dimensions; a nominal-only stack is not a finding" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "parts", .capability = "read_model", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "parts" },
            .{ .id = "datum", .capability = "define_datum", .kind = .work, .tier = .cheap, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "datum" },
            .{ .id = "worst_case", .capability = "apply_transform", .kind = .work, .phase = 2, .depends_on = &.{ "calibrate", "parts", "datum" }, .writes = "worst_case" },
            .{ .id = "contributions", .capability = "measure_contribution", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"worst_case"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"contributions"}, .retry_target = "worst_case", .writes = "tolerance_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "parts", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "dfm-dfa-review",
        .name = "DFM & DFA Review",
        .task = "可制造与可装配判定必须把工艺限值套到实际几何上，而不是看设计意图",
        .deliverable = "DFM/DFA 报告、工艺限值冲突清单、装配顺序与可达性检查",
        .source = "github.com/SPREsxm/claude-pcb-designer, github.com/almightyshui/Mechanical-AI-Skill, github.com/wogokoro/Agentic-CAD-Skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "a design is manufacturable only when the process limits are checked against the actual geometry, not the intent" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "geometry", .capability = "read_geometry", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "geometry" },
            .{ .id = "process", .capability = "read_process_limits", .kind = .work, .tier = .cheap, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "process" },
            .{ .id = "fab", .capability = "check_fab_limits", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{ "geometry", "process" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "assembly", .capability = "check_assembly_order", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"geometry"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "access", .capability = "check_fastener_access", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"geometry"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "fab", "assembly", "access" }, .retry_target = "geometry", .writes = "dfm_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "process", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "dieline-export",
        .name = "Dieline Export",
        .task = "刀模文件必须分层导出：Cut / Crease / Perforation 不能合并成一层，否则无法模切",
        .deliverable = "分层 DXF 刀模、材料利用率与出血检查、供应商可加工的工程文件",
        .source = "github.com/stoneproof-tech/PackagingWorkbench, github.com/sbarrak/packbox, github.com/wtgjx/design-dieline-packaging-skill",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "cut, crease and perforation must stay on separate layers; a flattened dieline cannot be cut" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "material", .capability = "read_material", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "material" },
            .{ .id = "dieline", .capability = "generate_dieline", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "dieline" },
            .{ .id = "layers", .capability = "apply_transform", .kind = .work, .tier = .cheap, .phase = 3, .depends_on = &.{ "calibrate", "dieline" }, .writes = "layers" },
            .{ .id = "cut", .capability = "check_cut_layer", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"layers"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "crease", .capability = "check_crease_layer", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"layers"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "perforation", .capability = "check_perforation_layer", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"layers"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "utilization", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{ "cut", "crease", "perforation" }, .retry_target = "dieline", .writes = "utilization" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 6, .depends_on = &.{"utilization"}, .retry_target = "utilization" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 7, .depends_on = &.{ "material", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 8, .depends_on = &.{"verify"} },
            .{ .id = "export", .capability = "export_dxf", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 9, .depends_on = &.{"approval"}, .writes = "dxf" },
        },
    },
    .{
        .id = "quality-loop",
        .name = "Quality Loop",
        .task = "质量回路：先写下什么最重要，再评估、行动、改进；自评分数不是度量",
        .deliverable = "质量标准 + 评估记录 + 行动项 + 下一轮可比较的度量",
        .source = "github.com/qualitymd/quality.md, github.com/blundergoat/goat-flow, github.com/stellarlinkco/skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "the loop ends only when the agreed criteria are measured on the artifact; a self-reported score is not a measurement" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "criteria", .capability = "define_criteria", .kind = .work, .tier = .cheap, .phase = 0, .writes = "criteria" },
            .{ .id = "evaluate", .capability = "evaluate_artifact", .kind = .work, .phase = 1, .depends_on = &.{"criteria"}, .writes = "evaluation" },
            .{ .id = "act", .capability = "apply_transform", .kind = .work, .phase = 2, .depends_on = &.{ "calibrate", "evaluate" }, .writes = "change" },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{"act"}, .retry_target = "evaluate", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "criteria", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "spec-loop",
        .name = "Spec Loop",
        .task = "规格先冻结再开工：完成定义必须是可检查的构建与测试，而不是模型自认为完成",
        .deliverable = "冻结规格 + 检查清单 + 实现 + 证据化验收",
        .source = "github.com/songyang0603/ds-spec-loop, github.com/MichelKerkmeester/skilled-agent-harness_spec-driven-loops, github.com/strelov1/spec-driven-tdd",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "the spec is frozen before work starts; done means the checks in the spec pass, not that the model believes it is done" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "spec", .capability = "freeze_spec", .kind = .work, .phase = 0, .writes = "spec" },
            .{ .id = "checks", .capability = "define_checks", .kind = .work, .tier = .cheap, .phase = 1, .depends_on = &.{"spec"}, .writes = "checks" },
            .{ .id = "implement", .capability = "apply_transform", .kind = .work, .phase = 2, .depends_on = &.{ "calibrate", "checks" }, .writes = "implementation" },
            .{ .id = "evidence", .capability = "collect_evidence", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"implement"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"evidence"}, .retry_target = "implement", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "spec", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "durable-state-loop",
        .name = "Durable State Loop",
        .task = "检查点不是完成的证明：它只记录哪些结果已存在、哪些节点还欠着；续跑不能重跑已完成节点",
        .deliverable = "可跨进程恢复的执行记录 + 待办节点清单 + 幂等续跑",
        .source = "github.com/rajivmehtaflex/graph-flow, github.com/Atakan-Emre/skillstate-kit, github.com/RobotSe7en/dagent",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "a checkpoint records what exists and what is still owed; resuming must not re-run a node that already has a result" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "state", .capability = "init_state", .kind = .work, .tier = .cheap, .phase = 0, .writes = "state" },
            .{ .id = "work", .capability = "apply_transform", .kind = .work, .phase = 1, .depends_on = &.{ "calibrate", "state" }, .writes = "result" },
            .{ .id = "checkpoint", .capability = "write_checkpoint", .kind = .work, .tier = .cheap, .phase = 2, .depends_on = &.{"work"}, .writes = "checkpoint" },
            .{ .id = "pending", .capability = "enumerate_pending", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"checkpoint"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"pending"}, .retry_target = "work", .writes = "findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "state", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "loop-pattern-picker",
        .name = "Loop Pattern Picker",
        .task = "按工作形状选回路模式：只有真正独立的单元才 fan-out；每种模式都必须有二元退出条件与硬上限",
        .deliverable = "模式选择 + 退出检查 + 上限 + 独立评审者安排",
        .source = "github.com/invincible04/awesome-loop-engineering, github.com/fltman/loop-engineer, github.com/mdayan8/everything-about-loop-engineering",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "the pattern is chosen by the work shape; a pattern without a binary exit check and a hard cap is rejected before any side effect" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "shape", .capability = "audit_work_shape", .kind = .work, .phase = 0, .writes = "shape" },
            .{ .id = "headless", .capability = "evaluate_pattern", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{ "calibrate", "shape" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "evaluator_optimizer", .capability = "evaluate_pattern", .kind = .fan_out, .tier = .cheap, .phase = 1, .depends_on = &.{ "calibrate", "shape" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "orchestrator", .capability = "evaluate_pattern", .kind = .fan_out, .tier = .standard, .phase = 1, .depends_on = &.{ "calibrate", "shape" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 2, .depends_on = &.{ "headless", "evaluator_optimizer", "orchestrator" }, .retry_target = "shape", .writes = "pattern_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 3, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 4, .depends_on = &.{ "shape", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "graph-runtime-audit",
        .name = "Graph Runtime Audit",
        .task = "审计图运行时实际执行了什么：fan-in 丢条目、门自确认、叙述边未删除都算失败",
        .deliverable = "运行时审计报告：真实执行层、丢条目、未测门、叙述边",
        .source = "github.com/cobusgreyling/graph-engineering, github.com/HM-Li/graph-engineering, github.com/marlingod/graph-engineering-kit",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "the runtime must report what it actually executed: a fan-in that drops entries or a gate that self-confirms is a failure, not a pass" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "plan", .capability = "read_plan", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "plan" },
            .{ .id = "layers", .capability = "apply_transform", .kind = .work, .tier = .cheap, .phase = 2, .depends_on = &.{ "calibrate", "plan" }, .writes = "layers" },
            .{ .id = "hidden", .capability = "detect_hidden_edges", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"layers"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "batch", .capability = "check_batch_integrity", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"layers"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 4, .depends_on = &.{ "hidden", "batch" }, .retry_target = "layers", .writes = "runtime_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "plan", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "pdn-impedance",
        .name = "Power Delivery Network",
        .task = "目标阻抗必须从实测去耦网络与回路电感推导；每一路载流宽度按实测电流与温升反推，不允许假设目标阻抗",
        .deliverable = "PDN 目标阻抗曲线、去耦网络表与载流宽度检查报告",
        .source = "github.com/dungnotnull/pcb-design-assistant-agent-skill, github.com/techsd/engineering-agent-skills, github.com/ChengminLi/AI-PCB-layout",
        .termination = .{ .kind = .trace_width, .limit = 0.3, .direction = .min, .max_iterations = 4, .criterion = "power trace width must be derived from measured current and temperature rise; an assumed target impedance is not a finding" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "power_net", .capability = "read_power_net", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "power_net" },
            .{ .id = "decoupling", .capability = "check_decoupling_network", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"power_net"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "loop_inductance", .capability = "measure_loop_inductance", .kind = .fan_out, .tier = .strong, .phase = 2, .depends_on = &.{"power_net"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "current_density", .capability = "check_current_density", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"power_net"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "decoupling", "loop_inductance", "current_density" }, .retry_target = "power_net", .writes = "pdn_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "power_net", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "fabrication-capability-check",
        .name = "Fabrication Capability Check",
        .task = "设计规则必须与所选工厂公布的能力逐项对照；对照不上的规则不能算通过，只能算未验证",
        .deliverable = "规则—能力对照表与不可制造项清单",
        .source = "github.com/SPREsxm/claude-pcb-designer, github.com/John-owo/pcb-agent-workflow, github.com/sunzhejian/hardware-design-to-manufacturing-skill",
        .termination = .{ .kind = .clearance, .limit = 0.2, .direction = .min, .max_iterations = 4, .criterion = "every design rule must be matched to a published fab capability line; a rule with no matching capability line is not a pass, it is unverified" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "capability", .capability = "read_fab_capability", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "capability" },
            .{ .id = "rules", .capability = "read_design_rules", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "rules" },
            .{ .id = "min_trace", .capability = "check_min_trace", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{ "capability", "rules" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "min_gap", .capability = "check_min_gap", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{ "capability", "rules" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "drill", .capability = "check_drill_annular", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{ "capability", "rules" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{ "min_trace", "min_gap", "drill" }, .retry_target = "rules", .writes = "fab_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "capability", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "engineering-drawing-gdt",
        .name = "Engineering Drawing & GD&T",
        .task = "特征控制框必须逐字保留公差与基准，并与模型实测尺寸对照；凭视觉判断的公差不算标注",
        .deliverable = "工程图与 GD&T 对照报告：逐字公差、基准链、不可测量项",
        .source = "github.com/Eklavya-San/CTQ-extraction, github.com/CavanJB/openclaw-pdf-to-cad-agent-skill, github.com/MeltFlexDevs/techdrawai-skills",
        .termination = .{ .kind = .fit_clearance, .limit = 0, .direction = .min, .max_iterations = 4, .criterion = "feature control frames must be transcribed verbatim and checked against measured geometry; a tolerance that cannot be measured is not a callout" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "model", .capability = "read_model", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "model" },
            .{ .id = "drawing", .capability = "read_drawing", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "drawing" },
            .{ .id = "callouts", .capability = "check_callouts", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{ "drawing", "model" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "datum", .capability = "check_datum_chain", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"drawing"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "callouts", "datum" }, .retry_target = "drawing", .writes = "gdt_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "model", "gate" }, .retry_target = "gate" },
        },
    },

    .{
        .id = "headless-eda-automation",
        .name = "Headless EDA Automation",
        .task = "先校验工具再校验结果：无头 EDA 工具必须真的可运行且版本一致，工具自报的通过不算通过",
        .deliverable = "工具校验记录 + 从工具输出实际读回的结果",
        .source = "github.com/michpro/kicad-tools, github.com/AvatarSD/KiSkill, github.com/pantojinho/hermes-kicad-pcb, github.com/yymqd/kicad-pcb-agent-skills",
        .termination = .{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "the tool must actually run and the result must be read back from its output; a tool that reports its own success is not a pass" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "tool", .capability = "verify_tool_available", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "tool" },
            .{ .id = "run", .capability = "apply_transform", .kind = .work, .tier = .cheap, .phase = 2, .depends_on = &.{ "calibrate", "tool" }, .writes = "output" },
            .{ .id = "readback", .capability = "read_tool_output", .kind = .work, .phase = 3, .depends_on = &.{"run"}, .writes = "readback" },
            .{ .id = "version", .capability = "check_tool_version", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"tool"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "integrity", .capability = "check_output_integrity", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"readback"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{ "version", "integrity" }, .retry_target = "run", .writes = "tool_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 6, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 7, .depends_on = &.{ "readback", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "conditional-routing",
        .name = "Conditional Routing",
        .task = "下一层跑什么必须由上游的实测结果决定；叙述上的先后不是路由，不能据此决定分支",
        .deliverable = "路由决策记录：输入度量、分支选择、被跳过的分支及原因",
        .source = "github.com/rajivmehtaflex/graph-flow, github.com/context4ai/agent-graph, github.com/Thanarak-q/graph-engineering-workflow, github.com/gootf/software-agent-sop",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 8, .criterion = "the next layer must be chosen from a measured upstream result; a route taken from narrative order is a failure, not a pass" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "source", .capability = "read_source", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "source" },
            .{ .id = "route", .capability = "evaluate_route", .kind = .gate, .phase = 2, .depends_on = &.{"source"}, .retry_target = "source" },
            .{ .id = "fast_lane", .capability = "run_fast_lane", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"route"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "deep_lane", .capability = "run_deep_lane", .kind = .fan_out, .tier = .strong, .phase = 3, .depends_on = &.{"route"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "fast_lane", "deep_lane" }, .retry_target = "route", .writes = "route_findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "source", "route" }, .retry_target = "route" },
        },
    },
    .{
        .id = "unfoolable-gate",
        .name = "Un-foolable Gate",
        .task = "完成必须是观察到的事实：模型的声明与观察必须分开记录，声明不能喂给门",
        .deliverable = "声明—观察对照表：每条声明是否有独立观察支撑",
        .source = "github.com/selmakcby/loop-engineering, github.com/Railly/skills, github.com/haidrrrry/loop-engineering-skills, github.com/MTEnt/special-skills",
        .termination = .{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "done means observed: a claim written by the model is not evidence, and a gate fed by a claim is a failure" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "claim", .capability = "read_claim", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "claim" },
            .{ .id = "observation", .capability = "observe_result", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "observation" },
            .{ .id = "compare", .capability = "check_claim_against_observation", .kind = .fan_out, .tier = .standard, .phase = 3, .depends_on = &.{ "claim", "observation" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"compare"}, .retry_target = "observation", .writes = "gate_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"observation"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "observation", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "fresh-context-batch",
        .name = "Fresh Context Batch",
        .task = "fan-out 必须在干净上下文里执行：读过的东西不能污染下一项判断，跨批泄漏必须可检测",
        .deliverable = "上下文隔离检查：每个判断的输入来源与泄漏点",
        .source = "github.com/odedha-dr/skills-vs-subagents, github.com/MouseRider/skills-tsvc, github.com/xing-0803/agent-runtime-safety-auditor, github.com/sneg55/agent-starter",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "each fan-out unit must run in a clean context; a judgement that inherits what it read is not independent" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "baseline", .capability = "read_baseline", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "baseline" },
            .{ .id = "batch", .capability = "run_batch", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{"baseline"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "leak", .capability = "detect_context_leak", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"batch"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "batch", "leak" }, .retry_target = "batch", .writes = "context_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "baseline", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "memory-ontology-layer",
        .name = "Memory As Infrastructure",
        .task = "先建本体层再抽取实体：知识必须可查询，不能塞进 prompt 里靠模型回忆",
        .deliverable = "本体层定义 + 可查询的实体关系与查询验证结果",
        .source = "github.com/mattgierhart/PRD-driven-context-engineering, github.com/npubird/KnowledgeGraphCourse, github.com/affectionatec/agentic-engineering, github.com/thedivergentai/Divergent-Skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "the ontology must be defined before extraction; knowledge that cannot be queried is not memory, it is prompt filler" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "ontology", .capability = "define_ontology", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "ontology" },
            .{ .id = "extract", .capability = "extract_entities", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"ontology"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "fuse", .capability = "consolidate", .kind = .fan_in, .batch = 25, .phase = 3, .depends_on = &.{"extract"}, .retry_target = "extract", .writes = "graph_store" },
            .{ .id = "query", .capability = "check_queryable", .kind = .gate, .phase = 4, .depends_on = &.{"fuse"}, .retry_target = "fuse" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "ontology", "query" }, .retry_target = "query" },
        },
    },
    .{
        .id = "packaging-transport-test",
        .name = "Packaging Transport Test",
        .task = "跌落与堆码必须按实际装载质量与公布的测试方法计算；没有跑过测试程序的包装不能声称通过",
        .deliverable = "运输测试计算表：跌落高度、堆码载荷、材料余量与未测试项",
        .source = "github.com/dungnotnull/packaging-design-advisor-agent-skill, github.com/stoneproof-tech/PackagingWorkbench, github.com/sbarrak/packbox",
        .termination = .{ .kind = .fit_clearance, .limit = 0, .direction = .min, .max_iterations = 4, .criterion = "drop and stack loads must be computed from the actual payload mass and a published test method; a package that was never tested cannot be declared pass" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "blank", .capability = "read_dieline", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "blank" },
            .{ .id = "payload", .capability = "read_payload", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "payload" },
            .{ .id = "drop", .capability = "check_drop_height", .kind = .fan_out, .tier = .standard, .phase = 2, .depends_on = &.{ "blank", "payload" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "stack", .capability = "check_stack_load", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{ "blank", "payload" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "drop", "stack" }, .retry_target = "payload", .writes = "transport_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "blank", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "human-gate-after-every-step",
        .name = "Human Gate After Every Step",
        .task = "不可逆步骤必须停在人工审批门前：门不能由模型自己批准，风险分级必须在执行后重算",
        .deliverable = "步骤—风险—审批对照表与未审批的不可逆动作清单",
        .source = "github.com/ChengminLi/AI-PCB-layout, github.com/richfrem/agent-plugins-skills, github.com/kumanaya/graph-engineer",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "every irreversible step must stop at a human approval gate; a gate approved by the model itself is not a gate" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 0 },
            .{ .id = "step", .capability = "execute_step", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "step" },
            .{ .id = "risk", .capability = "classify_risk", .kind = .gate, .phase = 2, .depends_on = &.{"step"}, .retry_target = "step" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 3, .depends_on = &.{"risk"} },
            .{ .id = "audit", .capability = "check_irreversible_coverage", .kind = .fan_out, .tier = .standard, .phase = 4, .depends_on = &.{"approval"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{"audit"}, .retry_target = "risk", .writes = "approval_findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "step", "risk" }, .retry_target = "risk" },
        },
    },
    .{
        .id = "parametric-model-rebuild",
        .name = "Parametric Model Rebuild",
        .task = "参数化模型必须由脚本重跑复现：重跑后的尺寸必须与目标逐项对照，手工改过的尺寸不算模型",
        .deliverable = "可重跑的 build 脚本 + 重跑尺寸与目标尺寸的对照表",
        .source = "github.com/Chocksy/fusion-agent-kit, github.com/forgent3d/forgent3d-skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "the model must be reproducible by re-running the script; a dimension that cannot be measured on the rebuilt model is not a finding" },
        .specs = &.{
            .{ .id = "targets", .capability = "read_parameters", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"targets"} },
            .{ .id = "script", .capability = "run_build_script", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "script" },
            .{ .id = "rebuild", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 3, .depends_on = &.{ "calibrate", "script" }, .writes = "rebuilt" },
            .{ .id = "features", .capability = "check_feature_tree", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"script"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "compare", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "rebuild", "features" }, .retry_target = "script", .writes = "rebuild_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"compare"}, .retry_target = "compare" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "targets", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "drawing-set-index",
        .name = "Drawing Set Index",
        .task = "工程图成套性：图框、标题栏、修订记录与图纸索引必须逐张核对；索引里存在的图必须在文件里真实存在",
        .deliverable = "图纸索引表：每张图的标题栏、修订记录与缺失项",
        .source = "github.com/capskov/luna-cad-sheet-layout, github.com/Eklavya-San/CTQ-extraction, github.com/MeltFlexDevs/techdrawai-skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "every sheet listed in the index must resolve to a real sheet; a title block filled from memory is not evidence" },
        .specs = &.{
            .{ .id = "index", .capability = "read_drawing_index", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"index"} },
            .{ .id = "sheets", .capability = "read_sheets", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "sheets" },
            .{ .id = "title_block", .capability = "check_title_block", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"sheets"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "revision", .capability = "check_revision_history", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"sheets"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "title_block", "revision" }, .retry_target = "sheets", .writes = "index_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "index", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "measured-dfam-slicing",
        .name = "Measured DfAM Slicing",
        .task = "可打印性必须来自实际切片：层数、材料体积、支撑面积与机器能力上限必须从切片输出读取，不能靠目测模型外观",
        .deliverable = "切片报告：层数、材料用量、支撑面积与机器能力对照",
        .source = "github.com/Silexperience210/hermes-3d-construction, github.com/heyixuan2/bambu-studio-ai",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "the slicer must actually run; numbers come from the slice output, not from how the model looks" },
        .specs = &.{
            .{ .id = "machine", .capability = "read_machine_capability", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"machine"} },
            .{ .id = "model", .capability = "read_model", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "model" },
            .{ .id = "slice", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 3, .depends_on = &.{ "calibrate", "model" }, .writes = "slice" },
            .{ .id = "support", .capability = "check_support_area", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"slice"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "material", .capability = "check_material_volume", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"slice"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{ "support", "material" }, .retry_target = "slice", .writes = "dfam_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 6, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 7, .depends_on = &.{ "machine", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "eco-packaging-score",
        .name = "Eco Packaging Score",
        .task = "环保评分必须按实际材料成分与装载质量计算：单一材料、可回收率、再生含量必须逐项可核对，不能凭印象打分",
        .deliverable = "循环经济性评分表：材料成分、可回收率与减材料改进项",
        .source = "github.com/dungnotnull/eco-packaging-design-agent-skill, github.com/dungnotnull/packaging-design-advisor-agent-skill",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "the score must be computed from the material list; a score asserted without materials is a failure" },
        .specs = &.{
            .{ .id = "materials", .capability = "read_material_list", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"materials"} },
            .{ .id = "load", .capability = "read_load_mass", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "load" },
            .{ .id = "recyclability", .capability = "check_recyclability", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"materials"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "mono_material", .capability = "check_mono_material", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"materials"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "score", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{ "recyclability", "mono_material" }, .retry_target = "materials", .writes = "eco_score" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"score"}, .retry_target = "score" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "materials", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "skill-provenance-integrity",
        .name = "Skill Provenance & Integrity",
        .task = "进入执行图的每个技能必须有出处与完整性校验：哈希不匹配或没有出处的技能不能参与判断",
        .deliverable = "出处与完整性对照表：每个技能的来源、哈希与校验结果",
        .source = "github.com/hbui290/agentic-skill-library, github.com/zot24/zskills, github.com/jeffreytse/grimoire",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "every skill in the run must have recorded provenance and a verified hash; unverified provenance fails the run" },
        .specs = &.{
            .{ .id = "registry", .capability = "read_skill_registry", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"registry"} },
            .{ .id = "skills", .capability = "read_skill_files", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "skills" },
            .{ .id = "hash", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 3, .depends_on = &.{ "calibrate", "skills" }, .writes = "hashes" },
            .{ .id = "provenance", .capability = "check_provenance", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"skills"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "safety", .capability = "check_safety_signal", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"skills"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{ "hash", "provenance", "safety" }, .retry_target = "skills", .writes = "integrity_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 6, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 7, .depends_on = &.{ "registry", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "postcondition-contract",
        .name = "Postcondition Contract",
        .task = "工具层必须有类型化契约与后置条件：后置条件失败必须作废该节点的结论，不能只记一条警告",
        .deliverable = "工具契约表：每个工具调用的输入类型、后置条件与是否真的被检查",
        .source = "github.com/wogokoro/Agentic-CAD-Skills, github.com/ldzhouquan/agent-harness-skill, github.com/sneg55/agent-starter",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "every tool call must have a declared postcondition that was actually checked; an unchecked postcondition fails the run" },
        .specs = &.{
            .{ .id = "contract", .capability = "read_tool_contract", .phase = 0 },
            .{ .id = "calibrate", .capability = "calibrate_transform", .phase = 1, .depends_on = &.{"contract"} },
            .{ .id = "call", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "call_result" },
            .{ .id = "checks", .capability = "check_postcondition", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"call"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"checks"}, .retry_target = "call", .writes = "contract_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "contract", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "ground-truth-evaluator",
        .name = "Ground-Truth Evaluator",
        .task = "自进化必须由冻结的未见测试集评估：评估者不能是生成者自己，测试集不能因为跑不过而被改写",
        .deliverable = "评估记录：冻结测试集、独立评估者、每条结果的来源与是否可复现",
        .source = "github.com/FishSerrie/skill-evolver, github.com/Sounder25/Foundational-Agent-Skills, github.com/itumor/dsh-plugin-recursive-optimizer",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "the evaluator must run on a frozen unseen set with a scorer independent from the generator; a test set rewritten to make a run pass is a failure" },
        .specs = &.{
            .{ .id = "frozen_set", .capability = "read_eval_set", .kind = .work, .phase = 0, .writes = "eval_set" },
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 1, .depends_on = &.{"frozen_set"} },
            .{ .id = "generate", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 2, .depends_on = &.{ "calibrate", "frozen_set" }, .writes = "candidate" },
            .{ .id = "score", .capability = "check_ground_truth", .kind = .fan_out, .tier = .cheap, .phase = 3, .depends_on = &.{"generate"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"score"}, .retry_target = "generate", .writes = "eval_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "frozen_set", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "harness2-evolution-loop",
        .name = "Harness² Evolution Loop",
        .task = "自进化必须按 Propose→Probe→Compose→Reflect 跑：Probe 必须在冻结的未见任务集上执行，护栏不可被回路改写，提议不能直接落库",
        .deliverable = "进化记录：提议、探测证据、组合补丁与反思结论，以及人工合并门的结果",
        .source = "github.com/itumor/dsh-plugin-recursive-optimizer, github.com/google-research/harness2, github.com/sneg55/agent-starter",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "propose must be followed by probe on the frozen unseen set before compose; a proposal that skips probe cannot be merged, and guardrails are not editable by the loop" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 0 },
            .{ .id = "evidence", .capability = "read_task_evidence", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "evidence" },
            .{ .id = "propose", .capability = "propose_change", .kind = .work, .tier = .standard, .phase = 2, .depends_on = &.{"evidence"}, .writes = "proposal" },
            .{ .id = "probe", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 3, .depends_on = &.{ "calibrate", "propose" }, .writes = "probe_evidence" },
            .{ .id = "reflect", .capability = "check_reflection", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"probe"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{"reflect"}, .retry_target = "probe", .writes = "evolution_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 6, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 7, .depends_on = &.{ "evidence", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 8, .depends_on = &.{"gate"} },
            .{ .id = "merge", .capability = "publish_change", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 9, .depends_on = &.{"approval"}, .writes = "merged" },
        },
    },
    .{
        .id = "skill-trigger-test",
        .name = "Skill Trigger Test",
        .task = "技能是否被触发必须用正例与负例测试：漏触发与误触发都算失败，不能靠模型自觉选择技能",
        .deliverable = "触发测试表：每条提示词应触发哪个技能、实际触发哪个、是否漏触发或误触发",
        .source = "github.com/netopsengineer/agent-skill-description-optimizer, github.com/greglas75/zuvo, github.com/jeffreytse/grimoire",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "trigger must be tested with positive and negative prompts; a skill that fires on the wrong request or misses the right one fails the run" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 0 },
            .{ .id = "descriptions", .capability = "read_skill_descriptions", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "descriptions" },
            .{ .id = "positives", .capability = "check_positive_trigger", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"descriptions"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "negatives", .capability = "check_negative_trigger", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"descriptions"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{ "positives", "negatives" }, .retry_target = "descriptions", .writes = "trigger_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "descriptions", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "publish-gate-set",
        .name = "Publish Gate Set",
        .task = "交付前必须跑完固定的门集合：任何一项缺失、跳过或被判定「不适用」都判失败，模型不能自行豁免",
        .deliverable = "门集合执行表：每一项门是否真的跑过、结果与豁免记录",
        .source = "github.com/belschak/publish-gate, github.com/ltlongtma/solo-sdlc, github.com/dwang-co/ship-team",
        .termination = .{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "every gate in the fixed set must have run before publishing; a skipped or self-exempted gate fails the run" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 0 },
            .{ .id = "deliverable", .capability = "read_deliverable", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "deliverable" },
            .{ .id = "gates", .capability = "check_gate_item", .kind = .fan_out, .tier = .cheap, .phase = 2, .depends_on = &.{"deliverable"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 3, .depends_on = &.{"gates"}, .retry_target = "deliverable", .writes = "publish_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 4, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 5, .depends_on = &.{ "deliverable", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 6, .depends_on = &.{"gate"} },
            .{ .id = "publish", .capability = "publish_deliverable", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 7, .depends_on = &.{"approval"}, .writes = "published" },
        },
    },
    .{
        .id = "predicate-router",
        .name = "Predicate Router",
        .task = "路由规则必须是可对执行状态求值的谓词（字段、运算符、阈值）：不能是模型的自然语言判断，求值失败必须走默认分支并记录",
        .deliverable = "路由规则表：谓词定义、求值输入、实际分支与默认分支回退记录",
        .source = "github.com/Alpha-Park/genpark-conditional-branch-router-state-evaluator-skill, github.com/Alpha-Park/genpark-stateful-agent-dag-node-executor-skill, github.com/CodeByZaigham/LangGraph-Workflows",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "the routing rule must be a declarative predicate evaluated over recorded state; a route taken from a model's wording or from narrative order fails" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 0 },
            .{ .id = "state", .capability = "read_state_dict", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "state" },
            .{ .id = "predicate", .capability = "compile_predicate", .kind = .work, .tier = .standard, .phase = 2, .depends_on = &.{"state"}, .writes = "predicate" },
            .{ .id = "route", .capability = "evaluate_route", .kind = .gate, .phase = 3, .depends_on = &.{"predicate"}, .retry_target = "predicate" },
            .{ .id = "branches", .capability = "run_branch", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"route"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{"branches"}, .retry_target = "route", .writes = "route_findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "state", "route" }, .retry_target = "route" },
        },
    },
    .{
        .id = "risk-gated-plan-review",
        .name = "Risk-Gated Plan Review",
        .task = "高风险计划必须在执行前被独立评审门拦住：评审者必须与生成者隔离，作者不能评审自己的计划",
        .deliverable = "风险分级与独立评审记录：风险判定依据、评审者独立性、是否真的在执行前完成",
        .source = "github.com/PGHQdev/second-opinion, github.com/GoatGit/super-code-review, github.com/ceoguy/ship-skill, github.com/xing-0803/agent-runtime-safety-auditor",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "a risky plan must be reviewed by an independent reviewer before execution; a review written by the plan's author is not a review" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 0 },
            .{ .id = "plan", .capability = "read_plan", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "plan" },
            .{ .id = "risk", .capability = "classify_risk", .kind = .gate, .phase = 2, .depends_on = &.{"plan"}, .retry_target = "plan" },
            .{ .id = "review", .capability = "independent_review", .kind = .fan_out, .tier = .strong, .phase = 3, .depends_on = &.{"risk"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"review"}, .retry_target = "review", .writes = "review_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "plan", "gate" }, .retry_target = "gate" },
            .{ .id = "approval", .capability = "human_approval", .kind = .approval, .risk = .high, .phase = 7, .depends_on = &.{"gate"} },
            .{ .id = "execute", .capability = "execute_plan", .kind = .work, .risk = .irreversible, .irreversible = true, .phase = 8, .depends_on = &.{"approval"}, .writes = "executed" },
        },
    },
    .{
        .id = "fea-simulation-evidence",
        .name = "FEA Simulation Evidence",
        .task = "仿真结果必须由可复现的求解运行产生：网格、边界条件与材料必须记录，凭印象的应力或温度不算验证",
        .deliverable = "仿真证据包：网格与节点数、边界条件、求解器与收敛状态、结果与解析对照",
        .source = "github.com/harshavarthan6767/openmechanical, github.com/k-telux/OpticalModeler, github.com/almightyshui/Mechanical-AI-Skill, github.com/evnchn-agentic/agentic-3d-modeling",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 5, .criterion = "every reported value must come from a reproducible solver run with recorded mesh and boundary conditions; a number without a solver run is not verification" },
        .specs = &.{
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 0 },
            .{ .id = "model", .capability = "read_model", .kind = .work, .phase = 1, .depends_on = &.{"calibrate"}, .writes = "model" },
            .{ .id = "mesh", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 2, .depends_on = &.{ "calibrate", "model" }, .writes = "mesh" },
            .{ .id = "boundary", .capability = "read_boundary_conditions", .kind = .work, .phase = 2, .depends_on = &.{"model"}, .writes = "boundary" },
            .{ .id = "solve", .capability = "run_solver", .kind = .fan_out, .tier = .strong, .phase = 3, .depends_on = &.{ "mesh", "boundary" }, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 4, .depends_on = &.{"solve"}, .retry_target = "mesh", .writes = "sim_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 5, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 6, .depends_on = &.{ "model", "gate" }, .retry_target = "gate" },
        },
    },
    .{
        .id = "state-machine-constrained-execution",
        .name = "State-Machine Constrained Execution",
        .task = "执行只能走校验过的工作流规格里声明的状态转移：模型临场发明的转移与跳阶段都判失败",
        .deliverable = "状态机对照表：规格声明的转移、实际走过的转移、非法转移与跳阶段记录",
        .source = "github.com/H20Zhang/workflow-skill, github.com/agent-ix/ix-flow, github.com/Mench-Li/GuardHarness, github.com/zju-CS-yzy/ipd-agent-workflow-skill, github.com/richfrem/agent-plugins-skills",
        .termination = .{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 6, .criterion = "execution may only move through transitions declared in the validated workflow spec; a transition invented by the model during the run is a failure" },
        .specs = &.{
            .{ .id = "spec", .capability = "read_workflow_spec", .kind = .work, .phase = 0, .writes = "spec" },
            .{ .id = "calibrate", .capability = "calibrate_transform", .kind = .work, .phase = 1, .depends_on = &.{"spec"} },
            .{ .id = "states", .capability = "enumerate_states", .kind = .work, .phase = 2, .depends_on = &.{"calibrate"}, .writes = "states" },
            .{ .id = "transitions", .capability = "apply_transform", .kind = .work, .tier = .standard, .phase = 3, .depends_on = &.{ "calibrate", "states" }, .writes = "transitions" },
            .{ .id = "run", .capability = "check_transition", .kind = .fan_out, .tier = .cheap, .phase = 4, .depends_on = &.{"transitions"}, .fresh_context = true, .max_parallel = 10 },
            .{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .phase = 5, .depends_on = &.{"run"}, .retry_target = "transitions", .writes = "state_findings" },
            .{ .id = "gate", .capability = "check_gate", .kind = .gate, .phase = 6, .depends_on = &.{"findings"}, .retry_target = "findings" },
            .{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .phase = 7, .depends_on = &.{ "spec", "gate" }, .retry_target = "gate" },
        },
    },
};

pub fn find(id: []const u8) ?Skill {
    for (catalog) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

pub fn build(gpa: Allocator, skill: Skill) !graph.Graph {
    var g = graph.Graph.init(gpa, skill.id, skill.name);
    errdefer g.deinit();

    try g.setTermination(skill.termination);
    for (skill.specs) |spec| {
        try g.add(.{
            .id = spec.id,
            .capability = spec.capability,
            .kind = spec.kind,
            .tier = spec.tier,
            .risk = spec.risk,
            .skill = skill.id,
            .phase = spec.phase,
            .depends_on = spec.depends_on,
            .writes = spec.writes,
            .rederive = spec.rederive,
            .retry_target = spec.retry_target,
            .batch = spec.batch,
            .irreversible = spec.irreversible,
            .fresh_context = spec.fresh_context,
            .max_parallel = spec.max_parallel,
        });
    }
    return g;
}

/// 每个技能图都必须先通过对抗性审查，再执行任何副作用。
pub fn reviewAll(gpa: Allocator) !usize {
    var total: usize = 0;
    for (catalog) |skill| {
        var g = try build(gpa, skill);
        defer g.deinit();
        try g.validate();
        const violations = try gates.adversarialReview(&g);
        defer {
            for (violations) |v| v.free(gpa);
            gpa.free(violations);
        }
        total += violations.len;
    }
    return total;
}

test "catalog skills build valid graphs" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 54), catalog.len);
    try std.testing.expect(find("bom-component-selector") != null);
    // 来自 GitHub skill 的图模板
    for ([_][]const u8{ "production-release", "model-compare", "printability-check", "emc-power-review", "work-shape-audit", "knowledge-graph-pipeline", "task-graph-protocol", "loop-engineer" }) |id| {
        try std.testing.expect(find(id) != null);
    }
    // 从 GitHub 上真实 PCB / CAD / 包装工程 skill 中提炼的新模板
    for ([_][]const u8{ "schematic-readability", "footprint-symbol-audit", "signal-integrity-review", "thermal-power-budget", "tolerance-stackup", "dfm-dfa-review", "dieline-export", "quality-loop", "spec-loop", "durable-state-loop", "loop-pattern-picker", "graph-runtime-audit", "pdn-impedance", "fabrication-capability-check", "engineering-drawing-gdt", "headless-eda-automation", "conditional-routing", "unfoolable-gate", "fresh-context-batch", "memory-ontology-layer", "packaging-transport-test", "human-gate-after-every-step", "parametric-model-rebuild", "drawing-set-index", "measured-dfam-slicing", "eco-packaging-score", "skill-provenance-integrity", "postcondition-contract", "ground-truth-evaluator", "harness2-evolution-loop", "skill-trigger-test", "publish-gate-set", "predicate-router", "risk-gated-plan-review", "fea-simulation-evidence", "state-machine-constrained-execution" }) |id| {
        try std.testing.expect(find(id) != null);
    }
    try std.testing.expect(find("missing") == null);

    const skill = find("pcb-design-review").?;
    var g = try build(gpa, skill);
    defer g.deinit();

    try g.validate();
    try std.testing.expect(g.termination != null);
    try std.testing.expect(g.stats().verify == 1);
    try std.testing.expect(g.stats().fan_out == 4);

    const layers = try g.layers();
    defer {
        for (layers) |l| gpa.free(l);
        gpa.free(layers);
    }
    // 同一层内的 fan-out 可并行：power_tree / subcircuits / esd / dfm 在同一层。
    try std.testing.expect(layers[2].len == 4);
}

test "every catalog skill passes its own adversarial review" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try reviewAll(gpa));
}

test "irreversible handoff nodes sit behind an approval or verification gate" {
    const gpa = std.testing.allocator;
    const skill = find("graph-orchestrator").?;
    var g = try build(gpa, skill);
    defer g.deinit();

    const deliver_idx = g.find("deliver").?;
    const deliver = g.nodeAt(deliver_idx);
    try std.testing.expect(deliver.irreversible);
    try std.testing.expectEqual(@as(usize, 1), deliver.depends_on.len);
    try std.testing.expectEqualStrings("approval", deliver.depends_on[0]);
    try std.testing.expectEqualStrings("no unresolved finding may remain; a failed verification feeds a targeted redo of the affected node only", g.termination.?.criterion);
}

test "fan-out degrades to batched tool calls without subagents" {
    const gpa = std.testing.allocator;
    const skill = find("emc-power-review").?;
    var g = try build(gpa, skill);
    defer g.deinit();

    // 有 subagent 工具：每个 fan-out 节点自带干净上下文与并行上限。
    const node = g.nodeAt(g.find("power_tree").?);
    try std.testing.expect(node.fresh_context);
    try std.testing.expectEqual(@as(usize, 10), node.max_parallel);

    // max_parallel == 0 时按 default_batch 分批，而不是一次吞下全部细节。
    var plain = graph.Graph.init(gpa, "graph-orchestrator", "no subagents");
    defer plain.deinit();
    try plain.add(.{ .id = "rubric", .capability = "define_rubric", .kind = .work });
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |id| {
        try plain.add(.{ .id = id, .capability = "audit", .kind = .fan_out, .depends_on = &.{"rubric"} });
    }
    try plain.add(.{ .id = "merge", .capability = "consolidate", .kind = .fan_in, .depends_on = &.{ "a", "b", "c", "d", "e" } });
    const batches = try plain.fanOutBatches(2);
    defer {
        for (batches) |b| gpa.free(b);
        gpa.free(batches);
    }
    // 5 个 fan-out 结果按批大小 2 拆成 3 批：宁可多跑一轮，也不能丢条目。
    try std.testing.expectEqual(@as(usize, 3), batches.len);
    try std.testing.expectEqual(@as(usize, 2), batches[0].len);
    try std.testing.expectEqual(@as(usize, 1), batches[2].len);

    var grouped = try build(gpa, find("emc-power-review").?);
    defer grouped.deinit();
    const gb = try grouped.fanOutBatches(20);
    defer {
        for (gb) |b| gpa.free(b);
        gpa.free(gb);
    }
    try std.testing.expectEqual(@as(usize, 1), gb.len);
    try std.testing.expectEqual(@as(usize, 4), gb[0].len);
}
