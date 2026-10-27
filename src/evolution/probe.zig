//! 探测阶段：把候选策略跑在固定任务集上（含未见的基准任务），记录证据。

const std = @import("std");
const constraints = @import("../design/constraints.zig");
const proposer = @import("proposer.zig");

const Allocator = std.mem.Allocator;

pub const Task = struct {
    id: []const u8,
    /// 固定未见测试集：用于判断进步是否真实。
    unseen: bool,
    measurements: []const constraints.Measurement,
};

pub const Attempt = struct {
    measurements: []const constraints.Measurement,
    iterations: usize,
    tool_calls: usize,
    tool_errors: usize,
    accepted: bool,
};

pub const StrategyFn = *const fn (ctx: *anyopaque, gpa: Allocator, task: Task, candidate: proposer.Candidate) anyerror!Attempt;

pub const Outcome = struct {
    candidate_id: []const u8,
    task_id: []const u8,
    unseen: bool,
    passed: bool,
    baseline_cost: f64,
    cost: f64,
    iterations: usize,
    tool_calls: usize,
    tool_errors: usize,
    accepted: bool,
};

pub const Prober = struct {
    gpa: Allocator,
    set: *const constraints.ConstraintSet,
    strategy: StrategyFn,
    ctx: *anyopaque,

    pub fn init(gpa: Allocator, set: *const constraints.ConstraintSet, strategy: StrategyFn, ctx: *anyopaque) Prober {
        return .{ .gpa = gpa, .set = set, .strategy = strategy, .ctx = ctx };
    }

    /// 软约束代价：越小越好（与 constraints.rank 的口径一致）。
    pub fn cost(self: *Prober, measurements: []const constraints.Measurement) f64 {
        var total: f64 = 0.0;
        for (measurements) |m| {
            const rule = self.set.findKind(m.kind) orelse continue;
            if (!constraints.satisfies(rule, m.value)) {
                total += 1.0;
                continue;
            }
            if (rule.direction == .max) total += m.value / rule.limit;
        }
        return total;
    }

    pub fn probe(self: *Prober, candidate: proposer.Candidate, task: Task) !Outcome {
        const attempt = try self.strategy(self.ctx, self.gpa, task, candidate);
        defer self.gpa.free(attempt.measurements);
        return .{
            .candidate_id = candidate.id,
            .task_id = task.id,
            .unseen = task.unseen,
            .passed = self.set.satisfiesHard(attempt.measurements),
            .baseline_cost = self.cost(task.measurements),
            .cost = self.cost(attempt.measurements),
            .iterations = attempt.iterations,
            .tool_calls = attempt.tool_calls,
            .tool_errors = attempt.tool_errors,
            .accepted = attempt.accepted,
        };
    }

    pub fn probeAll(self: *Prober, candidates: []const proposer.Candidate, tasks: []const Task) ![]Outcome {
        var out: std.ArrayList(Outcome) = .empty;
        errdefer out.deinit(
            self.gpa,
        );
        for (candidates) |c| {
            for (tasks) |t| try out.append(self.gpa, try self.probe(c, t));
        }
        return out.toOwnedSlice(
            self.gpa,
        );
    }
};

fn identityStrategy(_: *anyopaque, gpa: Allocator, task: Task, _: proposer.Candidate) anyerror!Attempt {
    return .{
        .measurements = try gpa.dupe(constraints.Measurement, task.measurements),
        .iterations = 1,
        .tool_calls = 1,
        .tool_errors = 0,
        .accepted = false,
    };
}

test "probe records evidence" {
    const gpa = std.testing.allocator;
    var set = constraints.ConstraintSet.init(gpa);
    defer set.deinit();
    try set.add(.{ .id = "min_trace_width", .kind = .trace_width, .limit = 0.2, .direction = .min, .severity = .hard });
    try set.add(.{ .id = "rat_length", .kind = .rat_length, .limit = 900, .direction = .max, .severity = .soft });

    const baseline = [_]constraints.Measurement{
        .{ .kind = .trace_width, .value = 0.25, .ref = "base" },
        .{ .kind = .rat_length, .value = 820, .ref = "base" },
    };
    const tasks = [_]Task{.{ .id = "b1", .unseen = true, .measurements = &baseline }};
    const candidates = [_]proposer.Candidate{.{ .id = "c1", .component = .system_prompt, .summary = "s", .body = "b", .rationale = "r" }};

    var prober = Prober.init(gpa, &set, identityStrategy, undefined);
    const outcomes = try prober.probeAll(&candidates, &tasks);
    defer gpa.free(outcomes);

    try std.testing.expectEqual(@as(usize, 1), outcomes.len);
    try std.testing.expect(outcomes[0].passed);
    try std.testing.expectApproxEqAbs(@as(f64, 820.0 / 900.0), outcomes[0].cost, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), outcomes[0].iterations);
}

test "probe fails hard violations" {
    const gpa = std.testing.allocator;
    var set = constraints.ConstraintSet.init(gpa);
    defer set.deinit();
    try set.add(.{ .id = "min_trace_width", .kind = .trace_width, .limit = 0.2, .direction = .min, .severity = .hard });

    const bad = [_]constraints.Measurement{.{ .kind = .trace_width, .value = 0.1, .ref = "x" }};
    const tasks = [_]Task{.{ .id = "b2", .unseen = false, .measurements = &bad }};
    const candidates = [_]proposer.Candidate{.{ .id = "c1", .component = .skills, .summary = "s", .body = "b", .rationale = "r" }};

    var prober = Prober.init(gpa, &set, identityStrategy, undefined);
    const outcomes = try prober.probeAll(&candidates, &tasks);
    defer gpa.free(outcomes);
    try std.testing.expect(!outcomes[0].passed);
}
