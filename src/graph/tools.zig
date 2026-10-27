//! 图执行层的工具面：Graph Flow / Graph Loop 接入统一工具注册表。
//!
//! 规划权在 Zig 侧，不在插件里：插件只提供能力，图决定什么先跑、什么可以 fan-out、
//! 什么必须停在人工审批门前。工具与 Agent、插件共用同一入口和权限检查。
//!
//! 能力实现（capability）在这里是「本地可证明的度量来源」：
//! - 显式提供的实测度量优先；
//! - 其次从设计引擎取真实数字（先校验工具，再校验结果）；
//! - fan-in 必须进多少出多少；
//! - gate / verify 只能从声明的源依赖重新推导，不能读上游的合成结论；
//! - 其余情况一律标记为推断（inferred），不能通过 measured-only 硬门。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const tools = @import("../core/tools.zig");
const sandbox = @import("../sandbox/policy.zig");
const claw = @import("../claw.zig");
const constraints = @import("../design/constraints.zig");
const project = @import("../design/project.zig");
const validation = @import("../design/validation.zig");
const design_tools = @import("../design/tools.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const gates = @import("gates.zig");
const skills = @import("skills.zig");
const executor = @import("executor.zig");
const ioc = @import("ioctx");

const Allocator = std.mem.Allocator;

/// fan-in 分层合并的默认批大小：超过批大小会丢细节，宁可多跑一轮。
pub const default_fan_in_batch: usize = 25;

/// 单个检查点文件的读取上限：检查点是执行记录，不该变成无界的历史。
pub const max_checkpoint_bytes: usize = 1024 * 1024;

pub const GraphToolError = error{
    SkillNotFound,
    PlanNotFound,
    MissingArgument,
    InvalidPlan,
    OutOfMemory,
};

pub const Workspace = struct {
    gpa: Allocator,
    policy: *sandbox.Policy,
    runtime: ?*claw.ClawRuntime = null,
    design: ?*design_tools.Workspace = null,
    plans: std.StringHashMap(graph.Graph),
    checkpoints: std.StringHashMap(std.json.Value),
    gate_set: gates.GateSet,
    /// 检查点目录：续跑常常发生在另一个进程里，内存里的检查点撑不过一次调用。
    /// 为空时检查点只在内存里，不落盘。
    checkpoint_dir: []const u8 = "",

    pub fn init(gpa: Allocator, policy: *sandbox.Policy) Workspace {
        return .{
            .gpa = gpa,
            .policy = policy,
            .plans = std.StringHashMap(graph.Graph).init(gpa),
            .checkpoints = std.StringHashMap(std.json.Value).init(gpa),
            .gate_set = gates.GateSet.init(gpa),
        };
    }

    pub fn deinit(self: *Workspace) void {
        var it = self.plans.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.plans.deinit();

        var cp = self.checkpoints.iterator();
        while (cp.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            ju.freeJsonValue(self.gpa, e.value_ptr.*);
        }
        self.checkpoints.deinit();

        self.gate_set.deinit();
    }

    /// 内置硬门：DRC 必须为零、结论必须实测、fan-in 必须完整、变换必须先标定。
    pub fn loadBuiltinGates(self: *Workspace) !void {
        var builtin = try gates.builtinHardGates(self.gpa);
        defer builtin.deinit();
        for (builtin.gates.items) |g| try self.gate_set.add(g);
    }

    /// 规划：从技能目录构建图。存下来的必须是可审阅的 DAG，而不是不透明的循环。
    pub fn plan(self: *Workspace, skill_id: []const u8) !*graph.Graph {
        const skill = skills.find(skill_id) orelse return error.SkillNotFound;
        const g = try skills.build(self.gpa, skill);
        errdefer {
            var copy = g;
            copy.deinit();
        }
        try g.validate();

        const entry = try self.plans.getOrPut(skill_id);
        if (entry.found_existing) {
            var old = entry.value_ptr.*;
            old.deinit();
            entry.value_ptr.* = g;
            return entry.value_ptr;
        }
        entry.key_ptr.* = try self.gpa.dupe(u8, skill_id);
        entry.value_ptr.* = g;
        return entry.value_ptr;
    }

    pub fn getPlan(self: *Workspace, skill_id: []const u8) ?*graph.Graph {
        return self.plans.getPtr(skill_id);
    }

    pub fn planCount(self: *const Workspace) usize {
        return self.plans.count();
    }

    pub fn setCheckpoint(self: *Workspace, skill_id: []const u8, value: std.json.Value) !void {
        const entry = try self.checkpoints.getOrPut(skill_id);
        const copied = try ju.copyJsonValue(self.gpa, value);
        if (entry.found_existing) {
            ju.freeJsonValue(self.gpa, entry.value_ptr.*);
            entry.value_ptr.* = copied;
            return;
        }
        entry.key_ptr.* = try self.gpa.dupe(u8, skill_id);
        entry.value_ptr.* = copied;
    }

    pub fn checkpoint(self: *const Workspace, skill_id: []const u8) ?std.json.Value {
        return self.checkpoints.get(skill_id);
    }

    fn checkpointPath(self: *const Workspace, skill_id: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.gpa, "{s}/{s}.json", .{ self.checkpoint_dir, skill_id });
    }

    /// 落盘检查点：续跑发生在另一个进程里时，必须能从磁盘读回执行记录。
    pub fn writeCheckpointFile(self: *Workspace, skill_id: []const u8, value: std.json.Value) !void {
        if (self.checkpoint_dir.len == 0) return;
        try self.policy.checkCapability(.write_file);
        const path = try self.checkpointPath(skill_id);
        defer self.gpa.free(path);
        const text = try ju.stringifyAlloc(self.gpa, value);
        defer self.gpa.free(text);
        ioc.cwd().makeDir(self.checkpoint_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        const file = try ioc.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(text);
    }

    pub fn readCheckpointFile(self: *Workspace, skill_id: []const u8) !?std.json.Value {
        if (self.checkpoint_dir.len == 0) return null;
        try self.policy.checkCapability(.read_file);
        const path = try self.checkpointPath(skill_id);
        defer self.gpa.free(path);
        const raw = try ioc.cwd().readFileAlloc(self.gpa, path, max_checkpoint_bytes);
        defer self.gpa.free(raw);
        return try ju.parseValue(self.gpa, raw);
    }

    pub fn registerTools(self: *Workspace, registry: *tools.Registry) !void {
        try registerTool(self, registry, "graph_skills", "列出图技能目录（Graph Flow 模板：阶段、门、终止条件与出处）", graph_skills_schema, graphSkillsTool);
        try registerTool(self, registry, "graph_plan", "把技能构建成可审阅的依赖图：真实边、隐藏边、分层与工作形状", graph_plan_schema, graphPlanTool);
        try registerTool(self, registry, "graph_run", "按图执行：分层执行、门失败定向重做、不可逆动作停在审批门前", graph_run_schema, graphRunTool);
        try registerTool(self, registry, "graph_gate", "用硬门评估一组度量：推断值不能通过 measured-only 门", graph_gate_schema, graphGateTool);
        try registerTool(self, registry, "graph_checkpoint", "读取上一次运行留下的检查点（可恢复的续跑契约）", graph_checkpoint_schema, graphCheckpointTool);
    }
};

const graph_skills_schema = "{\"type\":\"object\",\"properties\":{}}";
const graph_plan_schema = "{\"type\":\"object\",\"properties\":{\"skill\":{\"type\":\"string\"},\"input\":{\"type\":\"object\"}},\"required\":[\"skill\"]}";
const graph_run_schema = "{\"type\":\"object\",\"properties\":{\"skill\":{\"type\":\"string\"},\"project\":{\"type\":\"string\"},\"resume\":{\"type\":\"boolean\"},\"max_iterations\":{\"type\":\"integer\"},\"measurements\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"node\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\"},\"value\":{\"type\":\"number\"},\"ref\":{\"type\":\"string\"},\"measured\":{\"type\":\"boolean\"}}}}},\"required\":[\"skill\"]}";
const graph_gate_schema = "{\"type\":\"object\",\"properties\":{\"skill\":{\"type\":\"string\"},\"measurements\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"},\"value\":{\"type\":\"number\"},\"ref\":{\"type\":\"string\"},\"measured\":{\"type\":\"boolean\"}}}}},\"required\":[\"measurements\"]}";
const graph_checkpoint_schema = "{\"type\":\"object\",\"properties\":{\"skill\":{\"type\":\"string\"}},\"required\":[\"skill\"]}";

fn registerTool(ws: *Workspace, registry: *tools.Registry, name: []const u8, description: []const u8, schema_text: []const u8, execute: tools.ToolFn) !void {
    const gpa = ws.gpa;
    const schema = try ju.parseValue(gpa, schema_text);
    defer ju.freeJsonValue(gpa, schema);
    try registry.register(.{
        .name = name,
        .description = description,
        .parameters = schema,
        .plugin_id = "graph",
        .execute = execute,
    });
}

fn workspaceOf(ctx: *tools.ToolCtx) !*Workspace {
    const raw = ctx.graph_workspace orelse return error.MissingArgument;
    return @as(*Workspace, @ptrCast(@alignCast(raw)));
}

fn okJson(gpa: Allocator, obj: std.json.Value) !tools.ToolResult {
    const text = try ju.stringifyAlloc(gpa, obj);
    ju.freeJsonValue(gpa, obj);
    return .{ .ok = true, .content = text };
}

fn numberFromValue(value: std.json.Value) f64 {
    return graph.numberFromValue(value);
}

fn measurementJson(gpa: Allocator, node: graph.Node, kind: constraints.Kind, value: f64, ref: []const u8, measured: bool) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "node", try ju.strVal(gpa, node.id));
    try ju.putKey(gpa, &obj.object, "kind", try ju.strVal(gpa, @tagName(kind)));
    try ju.putKey(gpa, &obj.object, "value", .{ .float = value });
    try ju.putKey(gpa, &obj.object, "ref", try ju.strVal(gpa, ref));
    try ju.putKey(gpa, &obj.object, "measured", .{ .bool = measured });
    return obj;
}

const RunCtx = struct {
    gpa: Allocator,
    ws: *Workspace,
    st: *state.State,
    project: ?*project.DesignProject,
    measurements: std.json.Value,
};

fn terminationKind(st: *const state.State) constraints.Kind {
    if (st.graph.termination) |t| return t.kind;
    return .iterations;
}

/// 显式提供的实测度量：这是唯一能让 measured-only 硬门通过的东西。
fn explicitMeasurement(ctx: *RunCtx, node: graph.Node) ?std.json.Value {
    if (ctx.measurements != .array) return null;
    for (ctx.measurements.array.items) |entry| {
        if (entry != .object) continue;
        const item = entry.object;
        if (!std.mem.eql(u8, ju.objStr(item, "node"), node.id)) continue;
        const kind = constraints.kindFromString(ju.objStr(item, "kind")) orelse continue;
        const value = item.get("value") orelse continue;
        if (value != .integer and value != .float) continue;
        const measured = item.get("measured");
        return measurementJson(ctx.gpa, node, kind, numberFromValue(value), ju.objStr(item, "ref"), (if (measured) |m| m.bool else false)) catch null;
    }
    return null;
}

/// 从设计引擎取真实数字：先校验工具（解析文件），再校验结果。
fn projectMeasurement(ctx: *RunCtx, node: graph.Node) ?std.json.Value {
    const p = ctx.project orelse return null;
    const cap = node.capability;

    if (std.mem.eql(u8, cap, "read_kicad") or std.mem.eql(u8, cap, "check_gate")) {
        const report = validation.runDrc(ctx.gpa, &p.board, &p.constraints) catch return null;
        defer report.free();
        return measurementJson(ctx.gpa, node, .drc_errors, @floatFromInt(report.hard_count), p.id, true) catch null;
    }

    if (std.mem.eql(u8, cap, "interference_check")) {
        if (p.enclosure) |enc| {
            return measurementJson(ctx.gpa, node, .fit_clearance, enc.fitClearance(&p.board), p.id, true) catch null;
        }
    }

    return null;
}

fn capabilityRun(ctx: *anyopaque, gpa: Allocator, node: graph.Node, args: std.json.Value) anyerror!std.json.Value {
    const rc = @as(*RunCtx, @ptrCast(@alignCast(ctx)));

    // 1) 节点自带的显式度量优先（payload 里的 measurements 数组）。
    if (args == .object) {
        if (ju.objGet(args.object, "measurements")) |mv| {
            if (mv == .array) {
                for (mv.array.items) |entry| {
                    if (entry != .object) continue;
                    const kind = constraints.kindFromString(ju.objStr(entry.object, "kind")) orelse continue;
                    const value = entry.object.get("value") orelse continue;
                    if (value != .integer and value != .float) continue;
                    return measurementJson(gpa, node, kind, numberFromValue(value), ju.objStr(entry.object, "ref"), true);
                }
            }
        }
    }

    // 2) 运行级显式度量。
    if (explicitMeasurement(rc, node)) |v| return v;

    // 3) 设计引擎的真实测量。
    if (projectMeasurement(rc, node)) |v| return v;

    // 4) fan-in：进多少出多少，宁可多跑一轮也不能静默丢条目。
    if (node.kind == .fan_in) {
        var count: usize = 0;
        for (node.depends_on) |d| {
            const r = rc.st.get(d) orelse continue;
            if (r.ok and !r.skipped) count += 1;
        }
        var obj = try measurementJson(gpa, node, terminationKind(rc.st), @floatFromInt(count), node.id, true);
        errdefer ju.freeJsonValue(gpa, obj);
        try ju.putKey(gpa, &obj.object, "count", .{ .integer = @intCast(count) });
        return obj;
    }

    // 5) gate / verify：从声明的源依赖重新推导，不能读上游的合成结论。
    if (node.kind == .gate or node.kind == .verify) {
        for (node.depends_on) |d| {
            const r = rc.st.get(d) orelse continue;
            if (!r.ok or r.output != .object) continue;
            const o = r.output.object;
            const kind = constraints.kindFromString(ju.objStr(o, "kind")) orelse continue;
            const value = o.get("value") orelse continue;
            if (value != .integer and value != .float) continue;
            var obj = try measurementJson(gpa, node, kind, numberFromValue(value), ju.objStr(o, "ref"), r.measured);
            // 条件路由：下一层跑什么必须由这个实测值决定。
            // 满足终止条件走便宜分支，不满足就升级到强分支——路由不是由叙述顺序决定的。
            if (node.kind == .gate and std.mem.eql(u8, node.capability, "evaluate_route")) {
                if (rc.st.graph.termination) |t| {
                    const satisfied = constraints.satisfies(.{
                        .id = "termination",
                        .kind = t.kind,
                        .limit = t.limit,
                        .direction = t.direction,
                        .severity = .hard,
                    }, numberFromValue(value));
                    var cheap: ?[]const u8 = null;
                    var strong: ?[]const u8 = null;
                    for (rc.st.graph.nodes.items) |n| {
                        // 路由只在分支候选之间选择：复核与审批节点不属于候选集。
                        if (n.kind != .fan_out) continue;
                        for (n.depends_on) |dep| {
                            if (!std.mem.eql(u8, dep, node.id)) continue;
                            if (n.tier == .cheap) cheap = n.id;
                            if (n.tier == .strong) strong = n.id;
                        }
                    }
                    const chosen = if (satisfied) cheap else strong;
                    if (chosen != null) try ju.putKey(gpa, &obj.object, "route", try ju.strVal(gpa, chosen.?));
                }
            }
            return obj;
        }
    }

    // 6) 没有可证明的数字就是推断：measured=false，硬门会拒绝它。
    return measurementJson(gpa, node, terminationKind(rc.st), 0.0, node.id, false);
}

fn skillsJson(gpa: Allocator) !std.json.Value {
    var arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, arr);

    for (skills.catalog) |skill| {
        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "id", try ju.strVal(gpa, skill.id));
        try ju.putKey(gpa, &item.object, "name", try ju.strVal(gpa, skill.name));
        try ju.putKey(gpa, &item.object, "task", try ju.strVal(gpa, skill.task));
        try ju.putKey(gpa, &item.object, "deliverable", try ju.strVal(gpa, skill.deliverable));
        try ju.putKey(gpa, &item.object, "source", try ju.strVal(gpa, skill.source));
        try ju.putKey(gpa, &item.object, "criterion", try ju.strVal(gpa, skill.termination.criterion));
        try ju.putKey(gpa, &item.object, "max_iterations", .{ .integer = @intCast(skill.termination.max_iterations) });
        try ju.putKey(gpa, &item.object, "nodes", .{ .integer = @intCast(skill.specs.len) });
        try arr.array.append(item);
    }

    return arr;
}

fn graphSkillsTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.read_file);
    _ = args;
    return okJson(gpa, try skillsJson(gpa));
}

fn graphPlanTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.design_edit);

    const skill_id = ju.objStr(args.object, "skill");
    if (skill_id.len == 0) return error.MissingArgument;
    const skill = skills.find(skill_id) orelse return error.SkillNotFound;

    const g = try ws.plan(skill_id);
    if (ju.objGet(args.object, "input")) |input| {
        ju.freeJsonValue(gpa, g.input);
        g.input = try ju.copyJsonValue(gpa, input);
    }

    var obj = try g.toJson();
    errdefer ju.freeJsonValue(gpa, obj);

    try ju.putKey(gpa, &obj.object, "task", try ju.strVal(gpa, skill.task));
    try ju.putKey(gpa, &obj.object, "deliverable", try ju.strVal(gpa, skill.deliverable));
    try ju.putKey(gpa, &obj.object, "source", try ju.strVal(gpa, skill.source));

    const stats = g.stats();
    var stats_obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, stats_obj);
    try ju.putKey(gpa, &stats_obj.object, "nodes", .{ .integer = @intCast(stats.nodes) });
    try ju.putKey(gpa, &stats_obj.object, "fan_out", .{ .integer = @intCast(stats.fan_out) });
    try ju.putKey(gpa, &stats_obj.object, "fan_in", .{ .integer = @intCast(stats.fan_in) });
    try ju.putKey(gpa, &stats_obj.object, "gates", .{ .integer = @intCast(stats.gates) });
    try ju.putKey(gpa, &stats_obj.object, "verify", .{ .integer = @intCast(stats.verify) });
    try ju.putKey(gpa, &stats_obj.object, "approval", .{ .integer = @intCast(stats.approval) });
    try ju.putKey(gpa, &obj.object, "stats", stats_obj);

    const layers = try g.layers();
    defer {
        for (layers) |l| gpa.free(l);
        gpa.free(layers);
    }
    var layers_arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, layers_arr);
    for (layers) |layer| {
        var ids = ju.newArr(gpa);
        errdefer ju.freeJsonValue(gpa, ids);
        for (layer) |idx| try ids.array.append(try ju.strVal(gpa, g.nodeAt(idx).id));
        try layers_arr.array.append(ids);
    }
    try ju.putKey(gpa, &obj.object, "layers", layers_arr);

    const hidden = try g.hiddenEdges();
    defer {
        for (hidden) |e| gpa.free(e.reason);
        gpa.free(hidden);
    }
    var hidden_arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, hidden_arr);
    for (hidden) |e| {
        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "from", try ju.strVal(gpa, g.nodeAt(e.from).id));
        try ju.putKey(gpa, &item.object, "to", try ju.strVal(gpa, g.nodeAt(e.to).id));
        try ju.putKey(gpa, &item.object, "reason", try ju.strVal(gpa, e.reason));
        try hidden_arr.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "hidden_edges", hidden_arr);

    const shape = try g.shapeOfWork();
    defer shape.free(gpa);
    var shape_obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, shape_obj);
    try ju.putKey(gpa, &shape_obj.object, "pairs", .{ .integer = @intCast(shape.pairs) });
    try ju.putKey(gpa, &shape_obj.object, "real_edges", .{ .integer = @intCast(shape.real_edges) });
    try ju.putKey(gpa, &shape_obj.object, "narration_edges", .{ .integer = @intCast(shape.narration_edges) });
    try ju.putKey(gpa, &shape_obj.object, "independent_pairs", .{ .integer = @intCast(shape.independent_pairs) });
    try ju.putKey(gpa, &shape_obj.object, "recommendation", try ju.strVal(gpa, shape.recommendation));
    try ju.putKey(gpa, &obj.object, "shape", shape_obj);

    const violations = try gates.adversarialReview(g);
    defer {
        for (violations) |v| gpa.free(v.node_id);
        gpa.free(violations);
    }
    var violations_arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, violations_arr);
    for (violations) |v| {
        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "node", try ju.strVal(gpa, v.node_id));
        try ju.putKey(gpa, &item.object, "rule", try ju.strVal(gpa, v.rule));
        try violations_arr.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "review", violations_arr);

    return okJson(gpa, obj);
}

fn graphRunTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    const skill_id = ju.objStr(args.object, "skill");
    if (skill_id.len == 0) return error.MissingArgument;
    const skill = skills.find(skill_id) orelse return error.SkillNotFound;

    var g = try skills.build(gpa, skill);
    defer g.deinit();

    if (ju.objGet(args.object, "input")) |input| {
        ju.freeJsonValue(gpa, g.input);
        g.input = try ju.copyJsonValue(gpa, input);
    }

    const st = try gpa.create(state.State);
    defer gpa.destroy(st);
    st.* = state.State.init(gpa, &g);
    defer st.deinit();

    // 续跑：检查点里已完成的节点保留为结构化执行记录，不重新执行，
    // 也不从聊天历史里重新「发现」它们。
    var resumed = false;
    if (ju.objGet(args.object, "resume")) |rv| {
        if (rv == .bool and rv.bool) {
            var cp: ?std.json.Value = ws.checkpoint(skill_id);
            if (cp == null) cp = try ws.readCheckpointFile(skill_id);
            if (cp) |c| {
                const text = try ju.stringifyAlloc(gpa, c);
                defer gpa.free(text);
                st.deinit();
                st.* = try state.State.restore(gpa, text);
                resumed = true;
            }
        }
    }

    var run_ctx = RunCtx{
        .gpa = gpa,
        .ws = ws,
        .st = st,
        .project = null,
        .measurements = .null,
    };
    if (ws.design) |design_ws| {
        const project_id = ju.objStr(args.object, "project");
        if (project_id.len > 0) run_ctx.project = design_ws.get(project_id);
    }
    if (ju.objGet(args.object, "measurements")) |mv| {
        run_ctx.measurements = try ju.copyJsonValue(gpa, mv);
    }
    defer ju.freeJsonValue(gpa, run_ctx.measurements);

    var ex = executor.Executor.init(gpa, st.graph, st, &ws.gate_set);
    ex.capability = capabilityRun;
    ex.capability_ctx = @ptrCast(&run_ctx);
    // 显式的迭代上限覆盖：终止条件必须写下来，不能靠模型自己判断「够了」。
    const override = ju.objNum(args.object, "max_iterations");
    if (override > 0) {
        if (st.graph.termination) |t| {
            var copy = t;
            copy.max_iterations = @intCast(override);
            try st.graph.setTermination(copy);
        } else {
            try st.graph.setTermination(.{
                .kind = .iterations,
                .limit = 0,
                .direction = .max,
                .max_iterations = @intCast(override),
                .criterion = "explicit max_iterations override from the caller",
            });
        }
    }

    const calls_before = st.usage.tool_calls;
    const result = try ex.run();
    defer result.free(gpa);
    const new_tool_calls = st.usage.tool_calls - calls_before;

    const checkpoint = try st.checkpoint();
    defer ju.freeJsonValue(gpa, checkpoint);
    try ws.setCheckpoint(skill_id, checkpoint);
    try ws.writeCheckpointFile(skill_id, checkpoint);

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "skill", try ju.strVal(gpa, skill_id));
    try ju.putKey(gpa, &obj.object, "status", try ju.strVal(gpa, executor.statusLabel(result.status)));
    try ju.putKey(gpa, &obj.object, "answer", try ju.strVal(gpa, result.answer));
    try ju.putKey(gpa, &obj.object, "stopped_at", try ju.strVal(gpa, result.stopped_at));
    try ju.putKey(gpa, &obj.object, "resumed", .{ .bool = resumed });

    var skipped = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, skipped);
    var skipped_it = st.results.iterator();
    while (skipped_it.next()) |e| {
        if (e.value_ptr.skipped) try skipped.array.append(try ju.strVal(gpa, e.key_ptr.*));
    }
    try ju.putKey(gpa, &obj.object, "skipped", skipped);

    var reasons = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, reasons);
    for (result.reasons) |r| try reasons.array.append(try ju.strVal(gpa, r));
    try ju.putKey(gpa, &obj.object, "reasons", reasons);

    var usage = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, usage);
    try ju.putKey(gpa, &usage.object, "tool_calls", .{ .integer = @intCast(st.usage.tool_calls) });
    try ju.putKey(gpa, &usage.object, "tool_errors", .{ .integer = @intCast(st.usage.tool_errors) });
    try ju.putKey(gpa, &usage.object, "iterations", .{ .integer = @intCast(st.usage.iterations) });
    try ju.putKey(gpa, &usage.object, "layers_executed", .{ .integer = @intCast(st.usage.layers_executed) });

    const batches = try st.graph.fanOutBatches(default_fan_in_batch);
    defer {
        for (batches) |b| gpa.free(b);
        gpa.free(batches);
    }
    try ju.putKey(gpa, &usage.object, "fan_out_batches", .{ .integer = @intCast(batches.len) });
    // 续跑时 usage 是累计的：本次真正跑了多少次工具调用要单独报出来，
    // 否则「已完成节点不重跑」这件事看不出来。
    try ju.putKey(gpa, &usage.object, "new_tool_calls", .{ .integer = @intCast(new_tool_calls) });
    try ju.putKey(gpa, &obj.object, "usage", usage);

    return okJson(gpa, obj);
}

fn graphGateTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    const measurements_v = ju.objGet(args.object, "measurements") orelse return error.MissingArgument;
    if (measurements_v != .array) return error.MissingArgument;

    var measures: std.ArrayList(graph.Measurement) = .empty;
    defer {
        for (measures.items) |m| gpa.free(m.ref);
        measures.deinit(
            gpa,
        );
    }

    for (measurements_v.array.items) |entry| {
        if (entry != .object) continue;
        const item = entry.object;
        const kind = constraints.kindFromString(ju.objStr(item, "kind")) orelse continue;
        const value = item.get("value") orelse continue;
        if (value != .integer and value != .float) continue;
        const measured = item.get("measured");
        try measures.append(gpa, .{
            .kind = kind,
            .value = numberFromValue(value),
            .ref = try gpa.dupe(u8, ju.objStr(item, "ref")),
            .measured = if (measured) |m| m.bool else false,
        });
    }

    const report = try ws.gate_set.evaluate(measures.items);
    defer report.free();

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "passed", .{ .bool = report.passed() });
    try ju.putKey(gpa, &obj.object, "hard_count", .{ .integer = @intCast(report.hard_count) });

    var failures = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, failures);
    for (report.failures) |f| {
        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "gate", try ju.strVal(gpa, f.gate_id));
        try ju.putKey(gpa, &item.object, "ref", try ju.strVal(gpa, f.ref));
        try ju.putKey(gpa, &item.object, "value", .{ .float = f.measured });
        try ju.putKey(gpa, &item.object, "limit", .{ .float = f.limit });
        try ju.putKey(gpa, &item.object, "severity", try ju.strVal(gpa, @tagName(f.severity)));
        try ju.putKey(gpa, &item.object, "inferred", .{ .bool = f.inferred });
        try failures.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "failures", failures);

    return okJson(gpa, obj);
}

fn graphCheckpointTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.read_file);

    const skill_id = ju.objStr(args.object, "skill");
    if (skill_id.len == 0) return error.MissingArgument;

    if (ws.checkpoint(skill_id)) |cp| return okJson(gpa, try ju.copyJsonValue(gpa, cp));
    if (try ws.readCheckpointFile(skill_id)) |cp| return okJson(gpa, try ju.copyJsonValue(gpa, cp));

    // 没有运行过：给出续跑契约本身（全部节点待执行），而不是报错。
    const g = try ws.plan(skill_id);
    var st = state.State.init(gpa, g);
    defer st.deinit();
    return okJson(gpa, try st.checkpoint());
}

// --- 测试 ---

fn testCtx(gpa: Allocator, policy: *sandbox.Policy, ws: *Workspace) tools.ToolCtx {
    return .{ .gpa = gpa, .policy = policy, .graph_workspace = @ptrCast(ws) };
}

fn grantGraphCaps(policy: *sandbox.Policy) !void {
    try policy.grant(.read_file);
    try policy.grant(.run_tool);
    try policy.grant(.design_edit);
}

test "graph tools registered" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantGraphCaps(&policy);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);
    try std.testing.expectEqual(@as(usize, 5), reg.count());
}

test "graph plan reports the shape of the work before executing" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantGraphCaps(&policy);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const args = try ju.parseValue(gpa, "{\"skill\":\"pcb-design-review\"}");
    defer ju.freeJsonValue(gpa, args);
    var ctx = testCtx(gpa, &policy, &ws);
    const res = try reg.execute(&ctx, "graph_plan", args);
    defer res.free(gpa);

    const parsed = try ju.parseValue(gpa, res.content);
    defer ju.freeJsonValue(gpa, parsed);

    try std.testing.expectEqual(@as(i64, 4), parsed.object.get("stats").?.object.get("fan_out").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.object.get("stats").?.object.get("verify").?.integer);
    // 同一层的 fan-out 可并行：power_tree / subcircuits / esd / dfm。
    try std.testing.expectEqual(@as(usize, 4), parsed.object.get("layers").?.array.items[2].array.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.object.get("review").?.array.items.len);
    try std.testing.expect(parsed.object.get("shape").?.object.get("independent_pairs").?.integer > 0);
}

test "graph run stops at the human approval gate" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantGraphCaps(&policy);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const args = try ju.parseValue(gpa, "{\"skill\":\"graph-orchestrator\"}");
    defer ju.freeJsonValue(gpa, args);
    var ctx = testCtx(gpa, &policy, &ws);
    const res = try reg.execute(&ctx, "graph_run", args);
    defer res.free(gpa);

    const parsed = try ju.parseValue(gpa, res.content);
    defer ju.freeJsonValue(gpa, parsed);
    try std.testing.expectEqualStrings("needs_human", ju.objStr(parsed.object, "status"));
    try std.testing.expectEqualStrings("approval", ju.objStr(parsed.object, "stopped_at"));

    // 检查点必须留在工作区里，宿主重建能力后即可续跑。
    const cp = ws.checkpoint("graph-orchestrator");
    try std.testing.expect(cp != null);
    try std.testing.expect(cp.?.object.get("results") != null);
}

test "graph gate rejects inferred measurements" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantGraphCaps(&policy);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);
    try ws.loadBuiltinGates();

    const args = try ju.parseValue(gpa, "{\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"board\",\"measured\":false}]}");
    defer ju.freeJsonValue(gpa, args);
    var ctx = testCtx(gpa, &policy, &ws);
    const res = try reg.execute(&ctx, "graph_gate", args);
    defer res.free(gpa);

    const parsed = try ju.parseValue(gpa, res.content);
    defer ju.freeJsonValue(gpa, parsed);
    try std.testing.expect(!parsed.object.get("passed").?.bool);
    // 数值门（drc_errors）与来源门（measured_only）都会标记同一个推断值。
    try std.testing.expectEqual(@as(i64, 2), parsed.object.get("hard_count").?.integer);
    for (parsed.object.get("failures").?.array.items) |f| {
        try std.testing.expect(f.object.get("inferred").?.bool);
    }
}
