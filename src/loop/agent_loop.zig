//! Agent Loop：把 hook、审批、压缩、检查点、计划串成一个有界、可判定终止的循环。
//!
//! 三条不可协商的规则：
//! - 终止条件必须是可判定的二元谓词（binary）：prose 规则一律拒绝，不能靠模型
//!   自己判断"差不多了"；
//! - 每个工具的重试有上限；同一工具同一参数连续出现两次判 stall，连续多步没有新的
//!   实测事实判 no progress；
//! - 中断（interrupt）立刻改道，排队消息（queue）只在当前步结束后处理。
//!
//! 参考实现：Claude Code（hook 退出码语义、plan mode、subagent）、Codex（approval
//! 模式与 flight recorder/rewind）、Hermes Agent（自进化技能与周期性 nudge）、
//! harness2（探针 -> 评估 -> 晋升的自进化回路）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const constraints = @import("../design/constraints.zig");
const hooks = @import("hooks.zig");
const approval = @import("approval.zig");
const compaction = @import("compaction.zig");
const checkpoint = @import("checkpoint.zig");
const planning = @import("planning.zig");

pub const max_turns: usize = 32;
pub const max_tool_calls: usize = 64;
pub const max_retries_per_tool: usize = 3;

/// 同一工具同一参数连续出现两次：判 stall，而不是继续重试。
pub const stall_threshold: usize = 2;
/// 连续多步没有任何新的实测事实：判 no progress。
pub const no_progress_threshold: usize = 4;

pub const LoopError = error{
    ProseStopRuleRejected,
    ReadOnlyPlanMode,
    AuditTrailLost,
    OutOfMemory,
};

pub const Outcome = enum {
    running,
    completed,
    needs_human,
    budget_exhausted,
    stalled,
    no_progress,
    retries_exhausted,
};

/// 终止判定用的度量：measured = false 时不能通过 measured-only 门。
pub const Measurement = struct {
    kind: constraints.Kind,
    value: f64,
    ref: []const u8,
    measured: bool,
};

pub const StopRuleKind = enum { binary, prose };

pub const StopRule = struct {
    /// prose 不可判定：acceptStopRule 直接拒绝。
    kind: StopRuleKind,
    rule: constraints.Rule,
    criterion: []const u8,
};

pub fn acceptStopRule(gpa: Allocator, stop: StopRule) !StopRule {
    if (stop.kind == .prose) return error.ProseStopRuleRejected;
    return .{
        .kind = stop.kind,
        .rule = stop.rule,
        .criterion = try gpa.dupe(u8, stop.criterion),
    };
}

pub const write_tools = [_][]const u8{ "write_file", "design_edit", "apply_patch", "shell" };

pub fn isWriteTool(tool: []const u8) bool {
    for (write_tools) |w| {
        if (std.mem.eql(u8, w, tool)) return true;
    }
    return false;
}

pub const MessageKind = enum { interrupt, queue };

/// 收件箱：interrupt 立刻改道，queue 只在当前步结束后处理。
pub const Inbox = struct {
    gpa: Allocator,
    interrupt: ?[]const u8 = null,
    pending: std.ArrayList([]const u8),
    next: usize = 0,

    pub fn init(gpa: Allocator) Inbox {
        return .{ .gpa = gpa, .pending = .empty };
    }

    pub fn deinit(self: *Inbox) void {
        if (self.interrupt) |text| self.gpa.free(text);
        for (self.pending.items) |text| self.gpa.free(text);
        self.pending.deinit(self.gpa);
    }

    pub fn post(self: *Inbox, kind: MessageKind, text: []const u8) !void {
        const duped = try self.gpa.dupe(u8, text);
        if (kind == .interrupt) {
            if (self.interrupt) |old| self.gpa.free(old);
            self.interrupt = duped;
            return;
        }
        try self.pending.append(self.gpa, duped);
    }

    /// 返回副本：所有权交给调用方，收件箱自己那份立刻释放。
    pub fn takeInterrupt(self: *Inbox) !?[]const u8 {
        const text = self.interrupt orelse return null;
        self.interrupt = null;
        const copy = try self.gpa.dupe(u8, text);
        self.gpa.free(text);
        return copy;
    }

    pub fn takeQueued(self: *Inbox) !?[]const u8 {
        if (self.next >= self.pending.items.len) return null;
        const text = self.pending.items[self.next];
        self.next += 1;
        return try self.gpa.dupe(u8, text);
    }

    pub fn queuedCount(self: *const Inbox) usize {
        return self.pending.items.len - self.next;
    }
};

pub const Usage = struct {
    gpa: Allocator,
    turns: usize = 0,
    tool_calls: usize = 0,
    tool_errors: usize = 0,
    retries: std.StringHashMap(usize),

    pub fn init(gpa: Allocator) Usage {
        return .{ .gpa = gpa, .retries = std.StringHashMap(usize).init(gpa) };
    }

    pub fn deinit(self: *Usage) void {
        var it = self.retries.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.retries.deinit();
    }

    pub fn record(self: *Usage, tool: []const u8, ok: bool) !void {
        self.tool_calls += 1;
        if (!ok) self.tool_errors += 1;
        const entry = try self.retries.getOrPut(tool);
        if (!entry.found_existing) {
            // getOrPut 不会把新值置零：新键必须显式初始化，否则计数从垃圾开始。
            entry.key_ptr.* = try self.gpa.dupe(u8, tool);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    pub fn retriesFor(self: *const Usage, tool: []const u8) usize {
        return self.retries.get(tool) orelse 0;
    }
};

pub const StepResult = struct {
    turn: usize,
    tool: []const u8,
    hook_decision: hooks.Decision,
    approval_decision: approval.Decision,
    executed: bool,
    interrupted: bool,
    outcome: Outcome,
    reason: []const u8,

    pub fn free(self: *const StepResult, gpa: Allocator) void {
        gpa.free(self.reason);
    }
};

pub const Loop = struct {
    gpa: Allocator,
    hooks: *hooks.HookSet,
    approval: *approval.Approval,
    compaction: *compaction.Compaction,
    plan: *planning.Plan,
    recorder: *checkpoint.FlightRecorder,
    inbox: Inbox,
    usage: Usage,
    stop_rule: ?StopRule = null,
    turn: usize = 0,
    last_tool: []const u8 = "",
    last_args: []const u8 = "",
    repeated: usize = 0,
    no_progress: usize = 0,
    items: std.ArrayList(compaction.Item),

    pub fn init(
        gpa: Allocator,
        hook_set: *hooks.HookSet,
        approval_set: *approval.Approval,
        compaction_set: *compaction.Compaction,
        plan: *planning.Plan,
        recorder: *checkpoint.FlightRecorder,
    ) Loop {
        return .{
            .gpa = gpa,
            .hooks = hook_set,
            .approval = approval_set,
            .compaction = compaction_set,
            .plan = plan,
            .recorder = recorder,
            .inbox = Inbox.init(gpa),
            .usage = Usage.init(gpa),
            .items = .empty,
        };
    }

    pub fn deinit(self: *Loop) void {
        if (self.stop_rule) |rule| self.gpa.free(rule.criterion);
        self.inbox.deinit();
        self.usage.deinit();
        for (self.items.items) |it| self.gpa.free(it.content);
        self.items.deinit(self.gpa);
    }

    pub fn setStopRule(self: *Loop, stop: StopRule) !void {
        const accepted = try acceptStopRule(self.gpa, stop);
        if (self.stop_rule) |old| self.gpa.free(old.criterion);
        self.stop_rule = accepted;
    }

    pub fn appendItem(self: *Loop, kind: compaction.Kind, content: []const u8) !void {
        try self.items.append(self.gpa, .{
            .kind = kind,
            .turn = self.turn,
            .content = try self.gpa.dupe(u8, content),
        });
    }

    /// 压缩当前上下文：审计轨迹不能变短，否则整次压缩判失败。
    pub fn compactNow(self: *Loop) !compaction.Result {
        const gpa = self.gpa;
        const compacted = try self.compaction.compact(self.items.items);
        errdefer compacted.free(gpa);

        for (self.items.items) |it| gpa.free(it.content);
        self.items.clearRetainingCapacity();
        for (compacted.items) |it| {
            try self.items.append(gpa, .{
                .kind = it.kind,
                .turn = it.turn,
                .content = try gpa.dupe(u8, it.content),
            });
        }
        return compacted;
    }

    fn makeResult(self: *Loop, tool: []const u8, hook_decision: hooks.Decision, approval_decision: approval.Decision, executed: bool, interrupted: bool, outcome: Outcome, reason: []const u8) !StepResult {
        return .{
            .turn = self.turn,
            .tool = tool,
            .hook_decision = hook_decision,
            .approval_decision = approval_decision,
            .executed = executed,
            .interrupted = interrupted,
            .outcome = outcome,
            .reason = try self.gpa.dupe(u8, reason),
        };
    }

    /// 一步：预算 -> 中断 -> hook -> 审批 -> 计划模式 -> 重试上限 -> stall / no progress -> 检查点 -> 终止判定。
    pub fn step(self: *Loop, tool: []const u8, command: []const u8, measurement: ?Measurement) !StepResult {
        if (self.turn >= max_turns) {
            return self.makeResult(tool, .pass, .allow, false, false, .budget_exhausted, "turn budget exhausted");
        }
        if (self.usage.tool_calls >= max_tool_calls) {
            return self.makeResult(tool, .pass, .allow, false, false, .budget_exhausted, "tool call budget exhausted");
        }

        self.turn += 1;

        // 中断优先：立刻改道，之前的重复模式不再作为 stall 依据。
        var interrupted = false;
        if (self.inbox.interrupt != null) {
            interrupted = true;
            self.last_tool = "";
            self.last_args = "";
            self.repeated = 0;
        }

        const hook_eval = try self.hooks.evaluate(hooks.EventKind.pre_tool, tool, command);
        const hook_decision = hook_eval.decision;
        // Evaluation 里的 denied_segment 是分配出来的：StepResult 只保留枚举结论，
        // 所以这里必须在 step 结束前把它释放掉。
        defer if (hook_eval.denied_segment.len > 0) self.gpa.free(hook_eval.denied_segment);
        const approval_decision = self.approval.decide(tool, command);

        if (hook_decision == .deny) {
            return self.makeResult(tool, hook_decision, approval_decision, false, interrupted, .needs_human, "hook denied this step");
        }
        if (approval_decision == .deny) {
            return self.makeResult(tool, hook_decision, approval_decision, false, interrupted, .needs_human, "approval rule denied this step");
        }
        if (approval_decision == .ask) {
            return self.makeResult(tool, hook_decision, approval_decision, false, interrupted, .needs_human, "approval required before this step");
        }

        // plan mode 只读：写工具不进执行。
        if (!self.plan.allowsWrite() and isWriteTool(tool)) {
            return self.makeResult(tool, hook_decision, approval_decision, false, interrupted, .needs_human, "plan mode is read-only");
        }

        if (self.usage.retriesFor(tool) >= max_retries_per_tool) {
            return self.makeResult(tool, hook_decision, approval_decision, false, interrupted, .retries_exhausted, "retry cap reached for this tool");
        }

        // repeated 含当前这一次：第二次连续相同调用即判 stall。
        if (self.last_tool.len > 0 and std.mem.eql(u8, self.last_tool, tool) and std.mem.eql(u8, self.last_args, command)) {
            self.repeated += 1;
            if (self.repeated >= stall_threshold) {
                return self.makeResult(tool, hook_decision, approval_decision, false, interrupted, .stalled, "same tool with same arguments twice in a row");
            }
        } else {
            self.repeated = 1;
        }

        try self.usage.record(tool, true);
        self.last_tool = tool;
        self.last_args = command;

        const cp = try self.recorder.beginTurn(self.turn);
        try cp.record(tool, "", command, approval.isIrreversible(command));
        try self.recorder.endTurn();

        const measured = measurement != null and measurement.?.measured;
        if (measured) {
            self.no_progress = 0;
        } else {
            self.no_progress += 1;
            if (self.no_progress >= no_progress_threshold) {
                return self.makeResult(tool, hook_decision, approval_decision, true, interrupted, .no_progress, "no new measured fact for several steps");
            }
        }

        if (self.stop_rule) |rule| {
            // 只有真实测量才能通过终止门：推断值（measured = false）不算。
            if (measured and constraints.satisfies(rule.rule, measurement.?.value)) {
                return self.makeResult(tool, hook_decision, approval_decision, true, interrupted, .completed, rule.criterion);
            }
        }

        return self.makeResult(tool, hook_decision, approval_decision, true, interrupted, .running, "step executed");
    }
};

// --- 测试 ---

const TestCtx = struct {
    gpa: Allocator,
    hooks: *hooks.HookSet,
    approval: *approval.Approval,
    compaction: *compaction.Compaction,
    plan: *planning.Plan,
    recorder: *checkpoint.FlightRecorder,
    loop: *Loop,

    pub fn free(self: *TestCtx) void {
        self.loop.deinit();
        self.recorder.deinit();
        self.plan.deinit();
        self.hooks.deinit();
        self.approval.deinit();
        self.gpa.destroy(self.loop);
        self.gpa.destroy(self.recorder);
        self.gpa.destroy(self.plan);
        self.gpa.destroy(self.hooks);
        self.gpa.destroy(self.approval);
        self.gpa.destroy(self.compaction);
    }
};

/// 全部落在堆上：Loop 持有指向这些模块的指针，返回值副本会让指针指向别处。
fn testCtx(gpa: Allocator, mode: approval.Mode) !TestCtx {
    const hook_set = try gpa.create(hooks.HookSet);
    errdefer gpa.destroy(hook_set);
    const approval_set = try gpa.create(approval.Approval);
    errdefer gpa.destroy(approval_set);
    const compaction_set = try gpa.create(compaction.Compaction);
    errdefer gpa.destroy(compaction_set);
    const plan = try gpa.create(planning.Plan);
    errdefer gpa.destroy(plan);
    const recorder = try gpa.create(checkpoint.FlightRecorder);
    errdefer gpa.destroy(recorder);

    hook_set.* = hooks.HookSet.init(gpa);
    approval_set.* = approval.Approval.init(gpa, mode);
    compaction_set.* = compaction.Compaction.init(gpa, 200, 1);
    plan.* = try planning.Plan.init(gpa, "finish the board", .execute, 1000);
    recorder.* = checkpoint.FlightRecorder.init(gpa);

    const loop = try gpa.create(Loop);
    errdefer gpa.destroy(loop);
    loop.* = Loop.init(gpa, hook_set, approval_set, compaction_set, plan, recorder);

    return .{
        .gpa = gpa,
        .hooks = hook_set,
        .approval = approval_set,
        .compaction = compaction_set,
        .plan = plan,
        .recorder = recorder,
        .loop = loop,
    };
}

fn measure(kind: constraints.Kind, value: f64, measured: bool) Measurement {
    return .{ .kind = kind, .value = value, .ref = "board", .measured = measured };
}

fn repeat(comptime n: usize, comptime s: []const u8) [n * s.len]u8 {
    @setEvalBranchQuota(100000);
    var out: [n * s.len]u8 = undefined;
    for (0..n) |i| {
        for (s, 0..) |c, j| out[i * s.len + j] = c;
    }
    return out;
}

test "prose stop rules are rejected" {
    const gpa = std.testing.allocator;
    const prose = StopRule{
        .kind = .prose,
        .rule = .{ .id = "stop", .kind = .iterations, .limit = 3, .direction = .max, .severity = .hard },
        .criterion = "the model feels the design is good enough",
    };
    try std.testing.expectError(error.ProseStopRuleRejected, acceptStopRule(gpa, prose));

    const binary = StopRule{
        .kind = .binary,
        .rule = .{ .id = "drc", .kind = .drc_errors, .limit = 0, .direction = .max, .severity = .hard },
        .criterion = "drc_errors must equal zero",
    };
    const accepted = try acceptStopRule(gpa, binary);
    defer gpa.free(accepted.criterion);
    try std.testing.expectEqual(StopRuleKind.binary, accepted.kind);
}

test "binary stop rule completes only on a measured value" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .never);
    defer ctx.free();

    try ctx.loop.setStopRule(.{
        .kind = .binary,
        .rule = .{ .id = "drc", .kind = .drc_errors, .limit = 0, .direction = .max, .severity = .hard },
        .criterion = "drc_errors must equal zero",
    });

    const inferred = try ctx.loop.step("graph_gate", "gate", measure(.drc_errors, 0, false));
    defer inferred.free(gpa);
    try std.testing.expectEqual(Outcome.running, inferred.outcome);

    const real = try ctx.loop.step("graph_gate", "gate --project board", measure(.drc_errors, 0, true));
    defer real.free(gpa);
    try std.testing.expectEqual(Outcome.completed, real.outcome);
    try std.testing.expectEqualStrings("drc_errors must equal zero", real.reason);
}

test "approval ask and hook deny both stop for a human" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .on_request);
    defer ctx.free();

    const asked = try ctx.loop.step("shell", "git status", null);
    defer asked.free(gpa);
    try std.testing.expectEqual(Outcome.needs_human, asked.outcome);
    try std.testing.expect(!asked.executed);

    try ctx.approval.addRule("shell", "git status", .allow);
    const allowed = try ctx.loop.step("shell", "git status", null);
    defer allowed.free(gpa);
    try std.testing.expectEqual(Outcome.running, allowed.outcome);

    // 不可逆动作：会话级授权也覆盖不到。
    try ctx.approval.grantSession("shell", "*");
    const irreversible = try ctx.loop.step("shell", "git reset --hard", null);
    defer irreversible.free(gpa);
    try std.testing.expectEqual(Outcome.needs_human, irreversible.outcome);
    try std.testing.expectEqual(@as(usize, 1), ctx.approval.refused_grants);

    try ctx.hooks.denyPattern("rm");
    const denied = try ctx.loop.step("shell", "echo ok && rm -rf out", null);
    defer denied.free(gpa);
    try std.testing.expectEqual(Outcome.needs_human, denied.outcome);
    try std.testing.expectEqual(hooks.Decision.deny, denied.hook_decision);
}

test "stall and no progress are detected without calling the model" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .never);
    defer ctx.free();

    const first = try ctx.loop.step("graph_plan", "plan --skill pcb", null);
    defer first.free(gpa);
    try std.testing.expectEqual(Outcome.running, first.outcome);

    const second = try ctx.loop.step("graph_plan", "plan --skill pcb", null);
    defer second.free(gpa);
    try std.testing.expectEqual(Outcome.stalled, second.outcome);

    var ctx2 = try testCtx(gpa, .never);
    defer ctx2.free();

    var i: usize = 0;
    while (i < no_progress_threshold - 1) {
        const name = try std.fmt.allocPrint(gpa, "tool{d}", .{i});
        defer gpa.free(name);
        const r = try ctx2.loop.step(name, "run", null);
        defer r.free(gpa);
        try std.testing.expectEqual(Outcome.running, r.outcome);
        i += 1;
    }
    const stuck = try ctx2.loop.step("tool9", "run", null);
    defer stuck.free(gpa);
    try std.testing.expectEqual(Outcome.no_progress, stuck.outcome);
}

test "retry cap and turn budget stop the loop" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .never);
    defer ctx.free();

    // 参数每次都不同：这里考察的是重试上限，不是 stall。
    var i: usize = 0;
    while (i < max_retries_per_tool) {
        const args = try std.fmt.allocPrint(gpa, "run --skill {d}", .{i});
        defer gpa.free(args);
        const r = try ctx.loop.step("graph_run", args, measure(.iterations, @floatFromInt(i), true));
        defer r.free(gpa);
        try std.testing.expectEqual(Outcome.running, r.outcome);
        i += 1;
    }
    const capped = try ctx.loop.step("graph_run", "run --skill capped", null);
    defer capped.free(gpa);
    try std.testing.expectEqual(Outcome.retries_exhausted, capped.outcome);

    var big = try testCtx(gpa, .never);
    defer big.free();
    big.loop.turn = max_turns;
    const out = try big.loop.step("read_file", "read board", null);
    defer out.free(gpa);
    try std.testing.expectEqual(Outcome.budget_exhausted, out.outcome);
}

test "interrupt redirects immediately, queue waits for the current step" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .never);
    defer ctx.free();

    const first = try ctx.loop.step("graph_plan", "plan --skill pcb", null);
    defer first.free(gpa);
    try std.testing.expectEqual(Outcome.running, first.outcome);

    try ctx.loop.inbox.post(.queue, "add the via stitching");
    try ctx.loop.inbox.post(.interrupt, "stop, the stackup changed");

    const second = try ctx.loop.step("graph_plan", "plan --skill pcb", null);
    defer second.free(gpa);
    // 中断让重复计数归零：这一条不该判 stall。
    try std.testing.expect(second.interrupted);
    try std.testing.expectEqual(Outcome.running, second.outcome);

    const taken = try ctx.loop.inbox.takeInterrupt();
    defer if (taken) |text| gpa.free(text);
    try std.testing.expect(taken != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.loop.inbox.queuedCount());

    const queued = try ctx.loop.inbox.takeQueued();
    defer if (queued) |text| gpa.free(text);
    try std.testing.expectEqualStrings("add the via stitching", queued.?);
}

test "plan mode stays read-only inside the loop" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .never);
    defer ctx.free();

    ctx.plan.mode = .plan;
    const refused = try ctx.loop.step("write_file", "write src/board.kicad_pcb", null);
    defer refused.free(gpa);
    try std.testing.expectEqual(Outcome.needs_human, refused.outcome);
    try std.testing.expectEqualStrings("plan mode is read-only", refused.reason);

    const read = try ctx.loop.step("read_file", "read src/board.kicad_pcb", null);
    defer read.free(gpa);
    try std.testing.expectEqual(Outcome.running, read.outcome);
    try std.testing.expect(read.executed);
}

test "the loop keeps the audit trail when it compacts" {
    const gpa = std.testing.allocator;
    var ctx = try testCtx(gpa, .never);
    defer ctx.free();

    ctx.compaction.budget_tokens = 40;
    ctx.compaction.protected_last_n = 0;

    try ctx.loop.appendItem(.system, "system prompt that must never be compacted at all");
    try ctx.loop.appendItem(.tool_output, "drc report: 0 hard errors\n" ++ comptime repeat(60, "filler "));

    const res = try ctx.loop.compactNow();
    defer res.free(gpa);

    try std.testing.expect(res.compacted_count > 0);
    try std.testing.expectEqual(res.compacted_count, res.audit.len);
    try std.testing.expectEqualStrings("system prompt that must never be compacted at all", ctx.loop.items.items[0].content);
}
