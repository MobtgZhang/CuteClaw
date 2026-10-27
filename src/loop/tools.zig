//! Agent Loop 的工具面：把 hook、审批、压缩、检查点、计划、子代理与技能文件接入
//! 统一工具注册表，与 Agent、插件共用同一入口和权限检查。
//!
//! 与 graph 层一样，规划权在 Zig 侧：插件只提供能力，回路决定什么能跑、什么必须
//! 停在人工审批门前。三条不可协商的规则在这里同样成立：
//! - 终止条件必须是可判定的二元谓词，prose 规则一律拒绝；
//! - 只有真实测量（measured）能通过 measured-only 门，推断值不算；
//! - 写入边界重叠的子任务不能并行派发，子代理必须从 0 上下文起步。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const tools = @import("../core/tools.zig");
const sandbox = @import("../sandbox/policy.zig");
const constraints = @import("../design/constraints.zig");
const agent_loop = @import("agent_loop.zig");
const hooks = @import("hooks.zig");
const approval = @import("approval.zig");
const compaction = @import("compaction.zig");
const planning = @import("planning.zig");
const checkpoint = @import("checkpoint.zig");
const learning = @import("learning.zig");
const skillfile = @import("skillfile.zig");
const subagent = @import("subagent.zig");
const ioc = @import("ioctx");

const Allocator = std.mem.Allocator;

/// 单个技能文件的读取上限：SKILL.md 是说明书，不该变成无界的正文。
pub const max_skill_bytes: usize = 256 * 1024;

/// 自进化不能改写的路径前缀（与 src/evolution 的 guardrail 口径一致）。
pub const default_guardrail_prefixes = [_][]const u8{ "src/evolution/", "src/graph/gates.zig" };

pub const LoopToolError = error{
    MissingArgument,
    ProseStopRuleRejected,
    OutOfMemory,
};

pub const Workspace = struct {
    gpa: Allocator,
    policy: *sandbox.Policy,
    hooks: hooks.HookSet,
    approval: approval.Approval,
    compaction: compaction.Compaction,
    plan: planning.Plan,
    recorder: checkpoint.FlightRecorder,
    learning: learning.Learning,
    items: std.ArrayList(compaction.Item),
    skills_dir: []const u8 = "skills",

    pub fn init(gpa: Allocator, policy: *sandbox.Policy) !Workspace {
        var plan = try planning.Plan.init(gpa, "design task", .plan, 20000);
        errdefer plan.deinit();
        return .{
            .gpa = gpa,
            .policy = policy,
            .hooks = hooks.HookSet.init(gpa),
            .approval = approval.Approval.init(gpa, .on_request),
            .compaction = compaction.Compaction.init(gpa, 8000, 4),
            .plan = plan,
            .recorder = checkpoint.FlightRecorder.init(gpa),
            .learning = learning.Learning.init(gpa, &default_guardrail_prefixes),
            .items = .empty,
        };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.items.items) |it| self.gpa.free(it.content);
        self.items.deinit(self.gpa);
        self.plan.deinit();
        self.recorder.deinit();
        self.approval.deinit();
        self.hooks.deinit();
    }

    pub fn registerTools(self: *Workspace, registry: *tools.Registry) !void {
        try registerTool(self, registry, "loop_plan", "回路的可审阅计划：plan mode 只读、未完成任务不能宣告完成、预算与阻塞计数", loop_plan_schema, loopPlanTool);
        try registerTool(self, registry, "loop_delegate", "子代理派发：写入边界重叠即拒绝，子代理必须从 0 继承上下文起步", loop_delegate_schema, loopDelegateTool);
        try registerTool(self, registry, "loop_compact", "上下文压缩：审计轨迹不可被摘要掉，受保护条目必须原样保留", loop_compact_schema, loopCompactTool);
        try registerTool(self, registry, "loop_checkpoint", "每轮一个检查点：回退前先看 diff，不可逆效果一律拒绝回退", loop_checkpoint_schema, loopCheckpointTool);
        try registerTool(self, registry, "loop_stop_check", "终止判定：只接受二元谓词，prose 规则一律拒绝，推断值不能通过门", loop_stop_check_schema, loopStopCheckTool);
        try registerTool(self, registry, "loop_hooks", "hook 评估：逐段检查复合命令，hook 只能收紧决策，不能放宽", loop_hooks_schema, loopHooksTool);
        try registerTool(self, registry, "loop_approval", "审批决策：deny 优先于 allow 规则与会话级授权，不可逆动作必须问人", loop_approval_schema, loopApprovalTool);
        try registerTool(self, registry, "loop_skills", "读取 SKILL.md 技能：正例必须命中、负例必须不命中，DSH manifestVersion 仍须为 1", loop_skills_schema, loopSkillsTool);
    }
};

const loop_plan_schema = "{\"type\":\"object\",\"properties\":{\"goal\":{\"type\":\"string\"},\"mode\":{\"type\":\"string\",\"enum\":[\"plan\",\"execute\"]},\"budget_tokens\":{\"type\":\"integer\"},\"tasks\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"}}}},\"blocked\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"condition\":{\"type\":\"string\"}}},\"usage_tokens\":{\"type\":\"integer\"}}}";
const loop_delegate_schema = "{\"type\":\"object\",\"properties\":{\"tasks\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"goal\":{\"type\":\"string\"},\"write_scope\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"blocking\":{\"type\":\"boolean\"}}}},\"max_concurrent\":{\"type\":\"integer\"},\"review\":{\"type\":\"object\",\"properties\":{\"stage\":{\"type\":\"string\",\"enum\":[\"plan_review\",\"result_review\"]},\"passed\":{\"type\":\"boolean\"},\"reason\":{\"type\":\"string\"}}}},\"required\":[\"tasks\"]}";
const loop_compact_schema = "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"},\"turn\":{\"type\":\"integer\"},\"content\":{\"type\":\"string\"}}}},\"budget_tokens\":{\"type\":\"integer\"},\"protected_last_n\":{\"type\":\"integer\"}}}";
const loop_checkpoint_schema = "{\"type\":\"object\",\"properties\":{\"turn\":{\"type\":\"integer\"},\"entries\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"before\":{\"type\":\"string\"},\"after\":{\"type\":\"string\"},\"irreversible\":{\"type\":\"boolean\"}}}},\"rewind\":{\"type\":\"boolean\"}},\"required\":[\"turn\",\"entries\"]}";
const loop_stop_check_schema = "{\"type\":\"object\",\"properties\":{\"rule\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\",\"enum\":[\"binary\",\"prose\"]},\"constraint_kind\":{\"type\":\"string\"},\"limit\":{\"type\":\"number\"},\"direction\":{\"type\":\"string\",\"enum\":[\"min\",\"max\"]},\"severity\":{\"type\":\"string\",\"enum\":[\"hard\",\"soft\"]},\"criterion\":{\"type\":\"string\"}},\"required\":[\"kind\"]},\"measurements\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"},\"value\":{\"type\":\"number\"},\"ref\":{\"type\":\"string\"},\"measured\":{\"type\":\"boolean\"}}}}},\"required\":[\"rule\",\"measurements\"]}";
const loop_hooks_schema = "{\"type\":\"object\",\"properties\":{\"event\":{\"type\":\"string\"},\"tool\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"hooks\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"event\":{\"type\":\"string\"},\"pattern\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"}}}},\"deny_patterns\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"tool\"]}";
const loop_approval_schema = "{\"type\":\"object\",\"properties\":{\"mode\":{\"type\":\"string\",\"enum\":[\"never\",\"on_request\",\"untrusted\"]},\"tool\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"rules\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"tool\":{\"type\":\"string\"},\"pattern\":{\"type\":\"string\"},\"decision\":{\"type\":\"string\",\"enum\":[\"allow\",\"ask\",\"deny\"]}}}},\"grants\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"tool\":{\"type\":\"string\"},\"pattern\":{\"type\":\"string\"}}}}},\"required\":[\"tool\",\"command\"]}";
const loop_skills_schema = "{\"type\":\"object\",\"properties\":{\"dir\":{\"type\":\"string\"},\"phrase\":{\"type\":\"string\"},\"positives\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"negatives\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}";

fn registerTool(ws: *Workspace, registry: *tools.Registry, name: []const u8, description: []const u8, schema_text: []const u8, execute: tools.ToolFn) !void {
    const gpa = ws.gpa;
    const schema = try ju.parseValue(gpa, schema_text);
    defer ju.freeJsonValue(gpa, schema);
    try registry.register(.{
        .name = name,
        .description = description,
        .parameters = schema,
        .plugin_id = "loop",
        .execute = execute,
    });
}

fn workspaceOf(ctx: *tools.ToolCtx) !*Workspace {
    const raw = ctx.loop_workspace orelse return error.MissingArgument;
    return @as(*Workspace, @ptrCast(@alignCast(raw)));
}

fn okJson(gpa: Allocator, obj: std.json.Value) !tools.ToolResult {
    const text = try ju.stringifyAlloc(gpa, obj);
    ju.freeJsonValue(gpa, obj);
    return .{ .ok = true, .content = text };
}

fn numberFromValue(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0.0,
    };
}

fn boolFromValue(value: std.json.Value) bool {
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

// --- loop_plan ---

fn loopPlanTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    const plan = &ws.plan;

    const goal_text = ju.objStr(args.object, "goal");
    if (goal_text.len > 0) {
        const owned = try gpa.dupe(u8, goal_text);
        gpa.free(plan.goal);
        plan.goal = owned;
    }

    const mode_text = ju.objStr(args.object, "mode");
    if (mode_text.len > 0) {
        const mode = planning.modeFromString(mode_text) orelse return error.MissingArgument;
        plan.mode = mode;
    }
    if (args.object.get("budget_tokens")) |v| {
        if (v == .integer) plan.budget_tokens = @intCast(v.integer);
    }

    if (args.object.get("tasks")) |tasks| {
        if (tasks == .array) {
            for (tasks.array.items) |t| {
                if (t != .object) continue;
                const id = ju.objStr(t.object, "id");
                if (id.len == 0) continue;
                try plan.addTask(id, ju.objStr(t.object, "title"));
            }
        }
    }

    var blocked_now: ?bool = null;
    if (args.object.get("blocked")) |b| {
        if (b == .object) {
            const id = ju.objStr(b.object, "id");
            if (id.len > 0) blocked_now = try plan.markBlocked(id, ju.objStr(b.object, "condition"));
        }
    }

    if (args.object.get("usage_tokens")) |v| {
        if (v == .integer) plan.recordUsage(@intCast(v.integer));
    }

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "goal", try ju.strVal(gpa, plan.goal));
    try ju.putKey(gpa, &obj.object, "mode", try ju.strVal(gpa, @tagName(plan.mode)));
    try ju.putKey(gpa, &obj.object, "allows_write", .{ .bool = plan.allowsWrite() });
    try ju.putKey(gpa, &obj.object, "open", .{ .integer = @intCast(plan.openCount()) });
    try ju.putKey(gpa, &obj.object, "can_complete", .{ .bool = plan.canComplete() });
    try ju.putKey(gpa, &obj.object, "budget_exhausted", .{ .bool = plan.budgetExhausted() });

    var tasks_out = ju.newArr(gpa);
    for (plan.tasks.items) |t| {
        var item = ju.newObj(gpa);
        try ju.putKey(gpa, &item.object, "id", try ju.strVal(gpa, t.id));
        try ju.putKey(gpa, &item.object, "title", try ju.strVal(gpa, t.title));
        try ju.putKey(gpa, &item.object, "status", try ju.strVal(gpa, @tagName(t.status)));
        try ju.putKey(gpa, &item.object, "blocked_turns", .{ .integer = @intCast(t.blocked_turns) });
        try tasks_out.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "tasks", tasks_out);

    if (blocked_now) |b| try ju.putKey(gpa, &obj.object, "blocked_now", .{ .bool = b });

    const markdown = try plan.renderMarkdown();
    defer gpa.free(markdown);
    try ju.putKey(gpa, &obj.object, "markdown", try ju.strVal(gpa, markdown));

    return okJson(gpa, obj);
}

// --- loop_delegate ---

fn loopDelegateTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    // 即使这个工具不读工作区状态，也必须绑定到某个回路工作区：缺失即报错。
    _ = ws;
    try ctx.policy.checkCapability(.run_tool);

    const tasks_value = args.object.get("tasks") orelse return error.MissingArgument;
    if (tasks_value != .array) return error.MissingArgument;

    var tasks: std.ArrayList(subagent.Task) = .empty;
    defer {
        for (tasks.items) |t| {
            gpa.free(t.id);
            gpa.free(t.goal);
            for (t.write_scope) |s| gpa.free(s);
            gpa.free(t.write_scope);
        }
        tasks.deinit(
            gpa,
        );
    }

    for (tasks_value.array.items) |t| {
        if (t != .object) continue;
        const obj = t.object;
        const id = ju.objStr(obj, "id");
        if (id.len == 0) continue;
        var scope: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (scope.items) |s| gpa.free(s);
            scope.deinit(
                gpa,
            );
        }
        if (obj.get("write_scope")) |s| {
            if (s == .array) {
                for (s.array.items) |item| {
                    if (item != .string) continue;
                    try scope.append(gpa, try gpa.dupe(u8, item.string));
                }
            }
        }
        try tasks.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .goal = try gpa.dupe(u8, ju.objStr(obj, "goal")),
            .write_scope = try scope.toOwnedSlice(gpa),
            .blocking = boolFromValue(obj.get("blocking") orelse .null),
        });
    }

    const conflicts = try subagent.detectConflicts(gpa, tasks.items);
    defer {
        for (conflicts) |c| c.free(gpa);
        gpa.free(conflicts);
    }

    const limits = subagent.Limits{ .max_concurrent = @intCast(ju.objNum(args.object, "max_concurrent")) };

    var review = subagent.Review{ .stage = .plan_review, .passed = true, .reason = "" };
    if (args.object.get("review")) |r| {
        if (r == .object) {
            const stage_text = ju.objStr(r.object, "stage");
            if (std.mem.eql(u8, stage_text, "result_review")) review.stage = .result_review;
            review.passed = boolFromValue(r.object.get("passed") orelse .null);
            review.reason = ju.objStr(r.object, "reason");
        }
    }

    const dispatchable = try subagent.canDispatch(gpa, tasks.items, limits, review);

    var fresh: ?subagent.Context = null;
    if (tasks.items.len > 0) fresh = try subagent.freshContext(gpa, tasks.items[0]);
    if (fresh) |c| {
        defer gpa.free(c.task_id);
        defer gpa.free(c.prompt);
    }

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "can_delegate", .{ .bool = dispatchable });
    try ju.putKey(gpa, &obj.object, "tasks", .{ .integer = @intCast(tasks.items.len) });
    try ju.putKey(gpa, &obj.object, "dispatchable", .{ .integer = @intCast(subagent.dispatchable(tasks.items, limits)) });
    try ju.putKey(gpa, &obj.object, "max_concurrent", .{ .integer = @intCast(limits.max_concurrent) });
    try ju.putKey(gpa, &obj.object, "fresh_context", .{ .bool = fresh != null and fresh.?.inherited_messages == 0 });
    try ju.putKey(gpa, &obj.object, "review_stage", try ju.strVal(gpa, @tagName(review.stage)));

    var conflicts_out = ju.newArr(gpa);
    for (conflicts) |c| {
        var item = ju.newObj(gpa);
        try ju.putKey(gpa, &item.object, "task_a", try ju.strVal(gpa, c.task_a));
        try ju.putKey(gpa, &item.object, "task_b", try ju.strVal(gpa, c.task_b));
        try ju.putKey(gpa, &item.object, "path", try ju.strVal(gpa, c.path));
        try conflicts_out.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "conflicts", conflicts_out);

    return okJson(gpa, obj);
}

// --- loop_compact ---

fn loopCompactTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    var items: std.ArrayList(compaction.Item) = .empty;
    defer {
        for (items.items) |it| gpa.free(it.content);
        items.deinit(
            gpa,
        );
    }

    if (args.object.get("items")) |source| {
        if (source == .array) {
            for (source.array.items) |entry| {
                if (entry != .object) continue;
                const obj = entry.object;
                const kind = compaction.kindFromString(ju.objStr(obj, "kind")) orelse continue;
                try items.append(gpa, .{
                    .kind = kind,
                    .turn = @intCast(ju.objNum(obj, "turn")),
                    .content = try gpa.dupe(u8, ju.objStr(obj, "content")),
                });
            }
        }
    } else {
        for (ws.items.items) |it| try items.append(gpa, .{ .kind = it.kind, .turn = it.turn, .content = try gpa.dupe(u8, it.content) });
    }

    const budget = if (ju.objNum(args.object, "budget_tokens") > 0) ju.objNum(args.object, "budget_tokens") else 8000;
    const protected = if (args.object.get("protected_last_n") != null) ju.objNum(args.object, "protected_last_n") else 1;
    const local = compaction.Compaction.init(gpa, @intCast(budget), @intCast(protected));

    const result = try local.compact(items.items);
    defer result.free(gpa);

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "before_tokens", .{ .integer = @intCast(result.before_tokens) });
    try ju.putKey(gpa, &obj.object, "after_tokens", .{ .integer = @intCast(result.after_tokens) });
    try ju.putKey(gpa, &obj.object, "compacted_count", .{ .integer = @intCast(result.compacted_count) });
    try ju.putKey(gpa, &obj.object, "protected_kept", .{ .integer = @intCast(result.protected_kept) });
    try ju.putKey(gpa, &obj.object, "audit_preserved", .{ .bool = result.audit.len > 0 or result.compacted_count == 0 });

    var audit = ju.newArr(gpa);
    for (result.audit) |a| {
        var item = ju.newObj(gpa);
        try ju.putKey(gpa, &item.object, "turn", .{ .integer = @intCast(a.turn) });
        try ju.putKey(gpa, &item.object, "kind", try ju.strVal(gpa, @tagName(a.kind)));
        try ju.putKey(gpa, &item.object, "original_tokens", .{ .integer = @intCast(a.original_tokens) });
        try ju.putKey(gpa, &item.object, "summary", try ju.strVal(gpa, a.summary));
        try audit.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "audit", audit);

    return okJson(gpa, obj);
}

// --- loop_checkpoint ---

fn loopCheckpointTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    const entries_value = args.object.get("entries") orelse return error.MissingArgument;
    if (entries_value != .array) return error.MissingArgument;

    // endTurn 会销毁本轮检查点：diff 与回退必须在关闭之前完成。
    const cp = try ws.recorder.beginTurn(@intCast(ju.objNum(args.object, "turn")));

    var irreversible_count: usize = 0;
    for (entries_value.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;
        const path = ju.objStr(obj, "path");
        if (path.len == 0) continue;
        const bad = boolFromValue(obj.get("irreversible") orelse .null);
        if (bad) irreversible_count += 1;
        try cp.record(path, ju.objStr(obj, "before"), ju.objStr(obj, "after"), bad);
    }

    const diff = try checkpoint.diffPreview(gpa, cp);
    defer {
        for (diff) |d| gpa.free(d.path);
        gpa.free(diff);
    }

    var rewound: ?checkpoint.RewindResult = null;
    if (boolFromValue(args.object.get("rewind") orelse .null)) {
        rewound = try checkpoint.rewind(gpa, cp);
    }

    // endTurn 会销毁检查点：快照必须在关闭前取好。
    const turn = cp.turn;
    const entry_count = cp.entries.items.len;
    try ws.recorder.endTurn();

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "turn", .{ .integer = @intCast(turn) });
    try ju.putKey(gpa, &obj.object, "entries", .{ .integer = @intCast(entry_count) });
    try ju.putKey(gpa, &obj.object, "irreversible", .{ .integer = @intCast(irreversible_count) });
    try ju.putKey(gpa, &obj.object, "recorder_records", .{ .integer = @intCast(ws.recorder.count()) });

    var diff_out = ju.newArr(gpa);
    for (diff) |d| {
        var item = ju.newObj(gpa);
        try ju.putKey(gpa, &item.object, "path", try ju.strVal(gpa, d.path));
        try ju.putKey(gpa, &item.object, "removed", .{ .integer = @intCast(d.removed) });
        try ju.putKey(gpa, &item.object, "added", .{ .integer = @intCast(d.added) });
        try diff_out.array.append(item);
    }
    try ju.putKey(gpa, &obj.object, "diff", diff_out);

    if (rewound) |r| {
        var restored = ju.newArr(gpa);
        for (r.restored) |p| try restored.array.append(try ju.strVal(gpa, p));
        var refused = ju.newArr(gpa);
        for (r.refused) |p| try refused.array.append(try ju.strVal(gpa, p));
        try ju.putKey(gpa, &obj.object, "restored", restored);
        try ju.putKey(gpa, &obj.object, "refused", refused);
        r.free(gpa);
    }

    return okJson(gpa, obj);
}

// --- loop_stop_check ---

fn loopStopCheckTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    // 即使这个工具不读工作区状态，也必须绑定到某个回路工作区：缺失即报错。
    _ = ws;
    try ctx.policy.checkCapability(.run_tool);

    const rule_value = args.object.get("rule") orelse return error.MissingArgument;
    if (rule_value != .object) return error.MissingArgument;
    const rule_obj = rule_value.object;

    const kind_text = ju.objStr(rule_obj, "kind");
    const stop_kind = if (std.mem.eql(u8, kind_text, "prose")) agent_loop.StopRuleKind.prose else agent_loop.StopRuleKind.binary;

    const proposed = agent_loop.StopRule{
        .kind = stop_kind,
        .rule = .{
            .id = ju.objStr(rule_obj, "id"),
            .kind = constraints.kindFromString(ju.objStr(rule_obj, "constraint_kind")) orelse .iterations,
            .limit = numberFromValue(rule_obj.get("limit") orelse .null),
            .direction = constraints.directionFromString(ju.objStr(rule_obj, "direction")) orelse .max,
            .severity = constraints.severityFromString(ju.objStr(rule_obj, "severity")) orelse .hard,
        },
        .criterion = ju.objStr(rule_obj, "criterion"),
    };

    // prose 不可判定：这里直接拒绝，不进入评估。
    const accepted = try agent_loop.acceptStopRule(gpa, proposed);
    defer gpa.free(accepted.criterion);

    var checks = ju.newArr(gpa);
    var hard_count: usize = 0;
    var all_pass = true;

    const measurements = args.object.get("measurements") orelse return error.MissingArgument;
    if (measurements == .array) {
        for (measurements.array.items) |entry| {
            if (entry != .object) continue;
            const obj = entry.object;
            const kind = constraints.kindFromString(ju.objStr(obj, "kind")) orelse continue;
            const value = numberFromValue(obj.get("value") orelse .null);
            const measured = boolFromValue(obj.get("measured") orelse .null);
            const numeric_ok = constraints.satisfies(accepted.rule, value);
            const gate_ok = numeric_ok and measured;
            if (!gate_ok) hard_count += 1;
            if (!gate_ok) all_pass = false;

            var item = ju.newObj(gpa);
            try ju.putKey(gpa, &item.object, "kind", try ju.strVal(gpa, @tagName(kind)));
            try ju.putKey(gpa, &item.object, "value", .{ .float = value });
            try ju.putKey(gpa, &item.object, "ref", try ju.strVal(gpa, ju.objStr(obj, "ref")));
            try ju.putKey(gpa, &item.object, "measured", .{ .bool = measured });
            try ju.putKey(gpa, &item.object, "satisfied", .{ .bool = gate_ok });
            try checks.array.append(item);
        }
    }

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "accepted", .{ .bool = accepted.kind == .binary });
    try ju.putKey(gpa, &obj.object, "rule_kind", try ju.strVal(gpa, @tagName(accepted.kind)));
    try ju.putKey(gpa, &obj.object, "criterion", try ju.strVal(gpa, accepted.criterion));
    try ju.putKey(gpa, &obj.object, "measured_only", .{ .bool = true });
    try ju.putKey(gpa, &obj.object, "hard_count", .{ .integer = @intCast(hard_count) });
    try ju.putKey(gpa, &obj.object, "passed", .{ .bool = all_pass });
    try ju.putKey(gpa, &obj.object, "checks", checks);

    return okJson(gpa, obj);
}

// --- loop_hooks ---

fn loopHooksTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    const tool_name = ju.objStr(args.object, "tool");
    if (tool_name.len == 0) return error.MissingArgument;

    const event_text = ju.objStr(args.object, "event");
    const event = hooks.eventFromString(if (event_text.len > 0) event_text else "pre_tool") orelse return error.MissingArgument;
    const command = ju.objStr(args.object, "command");

    if (args.object.get("deny_patterns")) |patterns| {
        if (patterns == .array) {
            for (patterns.array.items) |p| {
                if (p != .string) continue;
                try ws.hooks.denyPattern(p.string);
            }
        }
    }

    if (args.object.get("hooks")) |hook_list| {
        if (hook_list == .array) {
            for (hook_list.array.items) |h| {
                if (h != .object) continue;
                const obj = h.object;
                const hook_event = hooks.eventFromString(ju.objStr(obj, "event")) orelse event;
                try ws.hooks.add(hook_event, ju.objStr(obj, "pattern"), ju.objStr(obj, "command"));
            }
        }
    }

    const evaluation = try ws.hooks.evaluate(event, tool_name, command);
    defer if (evaluation.denied_segment.len > 0) gpa.free(evaluation.denied_segment);

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "event", try ju.strVal(gpa, @tagName(event)));
    try ju.putKey(gpa, &obj.object, "tool", try ju.strVal(gpa, tool_name));
    try ju.putKey(gpa, &obj.object, "decision", try ju.strVal(gpa, @tagName(evaluation.decision)));
    try ju.putKey(gpa, &obj.object, "matched_hooks", .{ .integer = @intCast(evaluation.matched_hooks) });
    try ju.putKey(gpa, &obj.object, "segments_checked", .{ .integer = @intCast(evaluation.segments_checked) });
    try ju.putKey(gpa, &obj.object, "denied_segment", try ju.strVal(gpa, evaluation.denied_segment));
    try ju.putKey(gpa, &obj.object, "hooks_can_override_gates", .{ .bool = hooks.hooks_can_override_gates });

    return okJson(gpa, obj);
}

// --- loop_approval ---

fn loopApprovalTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.run_tool);

    const tool_name = ju.objStr(args.object, "tool");
    if (tool_name.len == 0) return error.MissingArgument;

    const mode_text = ju.objStr(args.object, "mode");
    if (mode_text.len > 0) {
        const mode = approval.modeFromString(mode_text) orelse return error.MissingArgument;
        ws.approval.mode = mode;
    }

    if (args.object.get("rules")) |rules| {
        if (rules == .array) {
            for (rules.array.items) |r| {
                if (r != .object) continue;
                const obj = r.object;
                const decision_text = ju.objStr(obj, "decision");
                const decision = if (std.mem.eql(u8, decision_text, "deny")) approval.Decision.deny else if (std.mem.eql(u8, decision_text, "ask")) approval.Decision.ask else approval.Decision.allow;
                try ws.approval.addRule(ju.objStr(obj, "tool"), ju.objStr(obj, "pattern"), decision);
            }
        }
    }

    if (args.object.get("grants")) |grants| {
        if (grants == .array) {
            for (grants.array.items) |g| {
                if (g != .object) continue;
                try ws.approval.grantSession(ju.objStr(g.object, "tool"), ju.objStr(g.object, "pattern"));
            }
        }
    }

    const command = ju.objStr(args.object, "command");
    const decision = ws.approval.decide(tool_name, command);

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "mode", try ju.strVal(gpa, @tagName(ws.approval.mode)));
    try ju.putKey(gpa, &obj.object, "tool", try ju.strVal(gpa, tool_name));
    try ju.putKey(gpa, &obj.object, "command", try ju.strVal(gpa, command));
    try ju.putKey(gpa, &obj.object, "decision", try ju.strVal(gpa, @tagName(decision)));
    try ju.putKey(gpa, &obj.object, "irreversible", .{ .bool = approval.isIrreversible(command) });
    try ju.putKey(gpa, &obj.object, "refused_grants", .{ .integer = @intCast(ws.approval.refused_grants) });

    return okJson(gpa, obj);
}

// --- loop_skills ---

fn appendStrings(gpa: Allocator, list: *std.ArrayList([]const u8), value: std.json.Value) !void {
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .string) continue;
        try list.append(gpa, try gpa.dupe(u8, item.string));
    }
}

fn loopSkillsTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.read_file);

    const skills_dir = ju.objStr(args.object, "dir");
    const dir_name = if (skills_dir.len > 0) skills_dir else ws.skills_dir;

    var positives: std.ArrayList([]const u8) = .empty;
    defer {
        for (positives.items) |p| gpa.free(p);
        positives.deinit(
            gpa,
        );
    }
    var negatives: std.ArrayList([]const u8) = .empty;
    defer {
        for (negatives.items) |p| gpa.free(p);
        negatives.deinit(
            gpa,
        );
    }
    try appendStrings(gpa, &positives, args.object.get("positives") orelse .null);
    try appendStrings(gpa, &negatives, args.object.get("negatives") orelse .null);

    var opened = ioc.cwd().openDir(dir_name, .{ .iterate = true }) catch |e| {
        if (e == error.FileNotFound) {
            var empty = ju.newObj(gpa);
            errdefer ju.freeJsonValue(gpa, empty);
            try ju.putKey(gpa, &empty.object, "dir", try ju.strVal(gpa, dir_name));
            try ju.putKey(gpa, &empty.object, "count", .{ .integer = 0 });
            try ju.putKey(gpa, &empty.object, "skills", ju.newArr(gpa));
            try ju.putKey(gpa, &empty.object, "note", try ju.strVal(gpa, "skill directory not found: SKILL.md files are required for trigger testing"));
            return okJson(gpa, empty);
        }
        return e;
    };
    defer opened.close();

    var out = ju.newArr(gpa);
    var count: usize = 0;
    var dsh_ok: usize = 0;
    var trigger_passed: usize = 0;

    var it = opened.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const skill_path = try std.fmt.allocPrint(gpa, "{s}/SKILL.md", .{entry.name});
        defer gpa.free(skill_path);
        const raw = opened.readFileAlloc(gpa, skill_path, max_skill_bytes) catch continue;
        defer gpa.free(raw);

        const parsed = skillfile.parse(gpa, skill_path, raw) catch continue;
        defer parsed.free(gpa);

        var compatible = false;
        const manifest_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{entry.name});
        defer gpa.free(manifest_path);
        if (opened.readFileAlloc(gpa, manifest_path, max_skill_bytes)) |manifest_raw| {
            defer gpa.free(manifest_raw);
            if (ju.parseValue(gpa, manifest_raw) catch null) |manifest| {
                defer ju.freeJsonValue(gpa, manifest);
                compatible = skillfile.dshManifestCompatible(manifest);
            }
        } else |_| {}

        var trigger: ?skillfile.TriggerResult = null;
        if (positives.items.len > 0 or negatives.items.len > 0) {
            trigger = try skillfile.triggerTest(&parsed, positives.items, negatives.items);
        }

        count += 1;
        if (compatible) dsh_ok += 1;
        if (trigger) |t| {
            defer t.free(gpa);
            if (t.passed) trigger_passed += 1;
        }

        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "name", try ju.strVal(gpa, parsed.name));
        try ju.putKey(gpa, &item.object, "description", try ju.strVal(gpa, parsed.description));
        try ju.putKey(gpa, &item.object, "path", try ju.strVal(gpa, parsed.path));
        try ju.putKey(gpa, &item.object, "dsh_manifest_version_1", .{ .bool = compatible });
        if (trigger) |t| {
            try ju.putKey(gpa, &item.object, "trigger_passed", .{ .bool = t.passed });
            try ju.putKey(gpa, &item.object, "positives_matched", .{ .integer = @intCast(t.positives_matched) });
            try ju.putKey(gpa, &item.object, "negatives_triggered", .{ .integer = @intCast(t.negatives_triggered) });
        }
        try out.array.append(item);
    }

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "dir", try ju.strVal(gpa, dir_name));
    try ju.putKey(gpa, &obj.object, "count", .{ .integer = @intCast(count) });
    try ju.putKey(gpa, &obj.object, "dsh_compatible", .{ .integer = @intCast(dsh_ok) });
    try ju.putKey(gpa, &obj.object, "trigger_passed", .{ .integer = @intCast(trigger_passed) });
    try ju.putKey(gpa, &obj.object, "skills", out);

    return okJson(gpa, obj);
}

// --- 测试 ---

fn testCtx(gpa: Allocator, policy: *sandbox.Policy, ws: *Workspace) tools.ToolCtx {
    return .{ .gpa = gpa, .policy = policy, .loop_workspace = @ptrCast(ws) };
}

fn grantLoopCaps(policy: *sandbox.Policy) !void {
    try policy.grant(.read_file);
    try policy.grant(.run_tool);
    try policy.grant(.design_edit);
}

fn runTool(gpa: Allocator, registry: *tools.Registry, policy: *sandbox.Policy, ws: *Workspace, name: []const u8, args_text: []const u8) !std.json.Value {
    const args = try ju.parseValue(gpa, args_text);
    defer ju.freeJsonValue(gpa, args);
    var ctx = testCtx(gpa, policy, ws);
    const res = try registry.execute(&ctx, name, args);
    defer res.free(gpa);
    return try ju.parseValue(gpa, res.content);
}

test "loop tools registered" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);
    try std.testing.expectEqual(@as(usize, 8), reg.count());
}

test "loop plan stays read-only and cannot complete with open tasks" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const parsed = try runTool(gpa, &reg, &policy, &ws, "loop_plan", "{\"mode\":\"plan\",\"tasks\":[{\"id\":\"t1\",\"title\":\"write hooks\"}]}");
    defer ju.freeJsonValue(gpa, parsed);
    try std.testing.expectEqualStrings("plan", ju.objStr(parsed.object, "mode"));
    try std.testing.expect(!parsed.object.get("allows_write").?.bool);
    try std.testing.expectEqual(@as(i64, 1), parsed.object.get("open").?.integer);
    try std.testing.expect(!parsed.object.get("can_complete").?.bool);

    const blocked = try runTool(gpa, &reg, &policy, &ws, "loop_plan", "{\"blocked\":{\"id\":\"t1\",\"condition\":\"test API unreachable\"}}");
    defer ju.freeJsonValue(gpa, blocked);
    try std.testing.expect(!blocked.object.get("blocked_now").?.bool);
    try std.testing.expectEqual(@as(i64, 1), blocked.object.get("tasks").?.array.items[0].object.get("blocked_turns").?.integer);
}

test "loop plan takes the goal from its input and keeps it" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const parsed = try runTool(gpa, &reg, &policy, &ws, "loop_plan", "{\"goal\":\"pcb stackup\",\"mode\":\"plan\",\"tasks\":[{\"id\":\"t1\",\"title\":\"stackup\"}]}");
    defer ju.freeJsonValue(gpa, parsed);
    try std.testing.expectEqualStrings("pcb stackup", ju.objStr(parsed.object, "goal"));

    const again = try runTool(gpa, &reg, &policy, &ws, "loop_plan", "{}");
    defer ju.freeJsonValue(gpa, again);
    try std.testing.expectEqualStrings("pcb stackup", ju.objStr(again.object, "goal"));
}

test "loop stop check rejects prose rules and inferred measurements" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    try std.testing.expectError(error.ProseStopRuleRejected, runTool(gpa, &reg, &policy, &ws, "loop_stop_check", "{\"rule\":{\"kind\":\"prose\",\"criterion\":\"looks good enough\"},\"measurements\":[]}"));

    const inferred = try runTool(gpa, &reg, &policy, &ws, "loop_stop_check", "{\"rule\":{\"kind\":\"binary\",\"constraint_kind\":\"drc_errors\",\"limit\":0,\"direction\":\"max\",\"severity\":\"hard\"},\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"board\",\"measured\":false}]}");
    defer ju.freeJsonValue(gpa, inferred);
    try std.testing.expect(parsedBool(inferred.object, "accepted"));
    try std.testing.expect(!parsedBool(inferred.object, "passed"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(inferred.object, "hard_count"));

    const measured = try runTool(gpa, &reg, &policy, &ws, "loop_stop_check", "{\"rule\":{\"kind\":\"binary\",\"constraint_kind\":\"drc_errors\",\"limit\":0,\"direction\":\"max\",\"severity\":\"hard\"},\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"board\",\"measured\":true}]}");
    defer ju.freeJsonValue(gpa, measured);
    try std.testing.expect(parsedBool(measured.object, "passed"));
    try std.testing.expectEqual(@as(i64, 0), parsedInt(measured.object, "hard_count"));
}

fn parsedBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn parsedInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

test "loop delegate refuses overlapping write scopes" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const overlap = try runTool(gpa, &reg, &policy, &ws, "loop_delegate", "{\"tasks\":[{\"id\":\"a\",\"goal\":\"layout\",\"write_scope\":[\"out/gerber\"],\"blocking\":false},{\"id\":\"b\",\"goal\":\"dfm\",\"write_scope\":[\"out/gerber/board.gbr\"],\"blocking\":false}],\"max_concurrent\":4,\"review\":{\"stage\":\"plan_review\",\"passed\":true,\"reason\":\"\"}}");
    defer ju.freeJsonValue(gpa, overlap);
    try std.testing.expectEqual(@as(usize, 1), overlap.object.get("conflicts").?.array.items.len);
    try std.testing.expect(!parsedBool(overlap.object, "can_delegate"));
    try std.testing.expect(parsedBool(overlap.object, "fresh_context"));

    const disjoint = try runTool(gpa, &reg, &policy, &ws, "loop_delegate", "{\"tasks\":[{\"id\":\"a\",\"goal\":\"layout\",\"write_scope\":[\"out/gerber\"],\"blocking\":false},{\"id\":\"b\",\"goal\":\"dfm\",\"write_scope\":[\"out/report\"],\"blocking\":false}],\"max_concurrent\":4,\"review\":{\"stage\":\"plan_review\",\"passed\":true,\"reason\":\"\"}}");
    defer ju.freeJsonValue(gpa, disjoint);
    try std.testing.expect(parsedBool(disjoint.object, "can_delegate"));
    try std.testing.expectEqual(@as(i64, 2), parsedInt(disjoint.object, "dispatchable"));
}

test "loop compaction cannot drop the audit trail" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const args_text = comptime "{\"items\":[{\"kind\":\"assistant\",\"turn\":1,\"content\":\"" ++ repeat(1200, "x") ++ "\"},{\"kind\":\"audit\",\"turn\":2,\"content\":\"gate failed: inferred measurement\"}],\"budget_tokens\":40,\"protected_last_n\":1}";
    const parsed = try runTool(gpa, &reg, &policy, &ws, "loop_compact", args_text);
    defer ju.freeJsonValue(gpa, parsed);

    try std.testing.expect(parsedInt(parsed.object, "after_tokens") <= parsedInt(parsed.object, "before_tokens"));
    try std.testing.expect(parsedInt(parsed.object, "compacted_count") >= 1);
    try std.testing.expect(parsedBool(parsed.object, "audit_preserved"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object, "protected_kept"));
}

fn repeat(comptime n: usize, comptime s: []const u8) [n * s.len]u8 {
    @setEvalBranchQuota(100000);
    var out: [n * s.len]u8 = undefined;
    for (0..n) |i| {
        for (0..s.len) |j| out[i * s.len + j] = s[j];
    }
    return out;
}

test "loop hooks and approval both gate a step" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const hook = try runTool(gpa, &reg, &policy, &ws, "loop_hooks", "{\"event\":\"pre_tool\",\"tool\":\"shell\",\"command\":\"echo ok && rm -rf out\",\"deny_patterns\":[\"rm\"]}");
    defer ju.freeJsonValue(gpa, hook);
    try std.testing.expectEqualStrings("deny", ju.objStr(hook.object, "decision"));
    try std.testing.expectEqual(@as(i64, 2), parsedInt(hook.object, "segments_checked"));
    try std.testing.expect(!parsedBool(hook.object, "hooks_can_override_gates"));

    const approval_result = try runTool(gpa, &reg, &policy, &ws, "loop_approval", "{\"mode\":\"on_request\",\"tool\":\"shell\",\"command\":\"git reset --hard\",\"grants\":[{\"tool\":\"shell\",\"pattern\":\"*\"}]}");
    defer ju.freeJsonValue(gpa, approval_result);
    // 不可逆动作永远要人工确认：会话级授权被拒绝，但决策是 ask，不是 deny。
    try std.testing.expectEqualStrings("ask", ju.objStr(approval_result.object, "decision"));
    try std.testing.expect(parsedBool(approval_result.object, "irreversible"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(approval_result.object, "refused_grants"));
}

test "loop checkpoint previews the diff before rewind and refuses irreversible entries" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const parsed = try runTool(gpa, &reg, &policy, &ws, "loop_checkpoint", "{\"turn\":1,\"entries\":[{\"path\":\"out/board.kicad_pcb\",\"before\":\"a b\",\"after\":\"a b c\",\"irreversible\":false},{\"path\":\"out/gerber\",\"before\":\"x\",\"after\":\"\",\"irreversible\":true}],\"rewind\":true}");
    defer ju.freeJsonValue(gpa, parsed);

    try std.testing.expectEqual(@as(i64, 2), parsedInt(parsed.object, "entries"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object, "irreversible"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object, "recorder_records"));
    try std.testing.expectEqual(@as(usize, 2), parsed.object.get("diff").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object.get("diff").?.array.items[0].object, "added"));
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("restored").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("refused").?.array.items.len);
}

test "loop skills reads SKILL.md and keeps DSH manifestVersion 1" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try grantLoopCaps(&policy);
    var ws = try Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const dir_name = ".cuteclaw-loop-skill-test";
    ioc.cwd().makeDir(dir_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    ioc.cwd().makeDir(dir_name ++ "/pcb-design-review") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var opened = try ioc.cwd().openDir(dir_name, .{ .iterate = true });
    defer opened.close();

    const skill_text = "---\nname: pcb-design-review\ndescription: PCB 审查技能：电源树/子电路/ESD/DFM 分项 fan-out\n---\n\n先分层再合并，结论必须可复推。\n";
    try opened.writeFile(.{ .sub_path = "pcb-design-review/SKILL.md", .data = skill_text });
    try opened.writeFile(.{ .sub_path = "pcb-design-review/package.json", .data = "{\"name\":\"pcb-design-review\",\"dsh\":{\"manifestVersion\":1}}" });

    const args_text = comptime "{\"dir\":\".cuteclaw-loop-skill-test\",\"positives\":[\"review the pcb stackup\"],\"negatives\":[\"write a blog post\"]}";
    const parsed = try runTool(gpa, &reg, &policy, &ws, "loop_skills", args_text);
    defer ju.freeJsonValue(gpa, parsed);

    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object, "count"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object, "dsh_compatible"));
    try std.testing.expectEqual(@as(i64, 1), parsedInt(parsed.object, "trigger_passed"));
    try std.testing.expectEqualStrings("pcb-design-review", ju.objStr(parsed.object.get("skills").?.array.items[0].object, "name"));

    ioc.cwd().deleteTree(dir_name) catch {};
}
