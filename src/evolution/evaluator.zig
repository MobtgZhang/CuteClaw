//! 评估阶段：plan-1 的六项指标（先淘汰硬约束违规，再比较质量）。

const std = @import("std");
const probe = @import("probe.zig");

const Allocator = std.mem.Allocator;

pub const Metrics = struct {
    engineering_pass_rate: f64,
    /// 相对基线的设计质量（>1 表示改善）。
    design_quality: f64,
    tool_reliability: f64,
    iterations_to_pass: f64,
    regression_rate: f64,
    human_acceptance: f64,
    samples: usize,
};

pub fn evaluate(outcomes: []const probe.Outcome) Metrics {
    if (outcomes.len == 0) return .{
        .engineering_pass_rate = 0.0,
        .design_quality = 0.0,
        .tool_reliability = 1.0,
        .iterations_to_pass = 0.0,
        .regression_rate = 0.0,
        .human_acceptance = 0.0,
        .samples = 0,
    };

    var passed: usize = 0;
    var accepted: usize = 0;
    var regressed: usize = 0;
    var quality_sum: f64 = 0.0;
    var quality_samples: usize = 0;
    var tool_calls: usize = 0;
    var tool_errors: usize = 0;
    var iterations: usize = 0;
    var iteration_samples: usize = 0;

    for (outcomes) |o| {
        if (o.passed) passed += 1;
        if (o.accepted) accepted += 1;
        if (o.cost > o.baseline_cost) regressed += 1;
        if (o.cost > 0.0 and o.baseline_cost > 0.0) {
            quality_sum += o.baseline_cost / o.cost;
            quality_samples += 1;
        }
        tool_calls += o.tool_calls;
        tool_errors += o.tool_errors;
        if (o.passed) {
            iterations += o.iterations;
            iteration_samples += 1;
        }
    }

    const total = outcomes.len;
    return .{
        .engineering_pass_rate = @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)),
        .design_quality = if (quality_samples > 0) quality_sum / @as(f64, @floatFromInt(quality_samples)) else 0.0,
        .tool_reliability = if (tool_calls > 0) 1.0 - (@as(f64, @floatFromInt(tool_errors)) / @as(f64, @floatFromInt(tool_calls))) else 1.0,
        .iterations_to_pass = if (iteration_samples > 0) @as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(iteration_samples)) else 0.0,
        .regression_rate = @as(f64, @floatFromInt(regressed)) / @as(f64, @floatFromInt(total)),
        .human_acceptance = @as(f64, @floatFromInt(accepted)) / @as(f64, @floatFromInt(total)),
        .samples = total,
    };
}

pub const RankedCandidate = struct {
    candidate_id: []const u8,
    eliminated: bool,
    metrics: Metrics,
};

/// 按候选聚合：硬约束未全通过的候选先淘汰，再按质量与迭代次数排序。
pub fn rank(gpa: Allocator, outcomes: []const probe.Outcome) ![]RankedCandidate {
    var groups = std.StringHashMap(std.ArrayList(probe.Outcome)).init(gpa);
    defer {
        var it = groups.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(gpa);
            gpa.free(e.key_ptr.*);
        }
        groups.deinit();
    }

    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(gpa);

    for (outcomes) |o| {
        const key = try gpa.dupe(u8, o.candidate_id);
        const entry = try groups.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            try order.append(gpa, key);
        } else {
            gpa.free(key);
        }
        try entry.value_ptr.append(gpa, o);
    }

    var out: std.ArrayList(RankedCandidate) = .empty;
    errdefer out.deinit(gpa);
    for (order.items) |id| {
        const list = groups.get(id) orelse continue;
        const metrics = evaluate(list.items);
        try out.append(gpa, .{
            .candidate_id = try gpa.dupe(u8, id),
            .eliminated = metrics.engineering_pass_rate < 1.0,
            .metrics = metrics,
        });
    }

    std.sort.insertion(RankedCandidate, out.items, {}, rankedLessThan);
    return out.toOwnedSlice(gpa);
}

fn rankedLessThan(_: void, a: RankedCandidate, b: RankedCandidate) bool {
    if (a.eliminated != b.eliminated) return !a.eliminated;
    if (a.metrics.design_quality != b.metrics.design_quality) return a.metrics.design_quality > b.metrics.design_quality;
    return a.metrics.iterations_to_pass < b.metrics.iterations_to_pass;
}

test "evaluator metrics" {
    const gpa = std.testing.allocator;
    const outcomes = [_]probe.Outcome{
        .{ .candidate_id = "A", .task_id = "t1", .unseen = true, .passed = true, .baseline_cost = 0.91, .cost = 0.95, .iterations = 2, .tool_calls = 4, .tool_errors = 0, .accepted = true },
        .{ .candidate_id = "A", .task_id = "t2", .unseen = true, .passed = true, .baseline_cost = 0.91, .cost = 0.74, .iterations = 3, .tool_calls = 6, .tool_errors = 1, .accepted = false },
        .{ .candidate_id = "C", .task_id = "t1", .unseen = true, .passed = false, .baseline_cost = 0.91, .cost = 0.66, .iterations = 1, .tool_calls = 2, .tool_errors = 0, .accepted = false },
    };

    const metrics = evaluate(&outcomes);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), metrics.engineering_pass_rate, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), metrics.regression_rate, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), metrics.human_acceptance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0 / 12.0), metrics.tool_reliability, 0.0001);

    const ranked = try rank(gpa, &outcomes);
    defer {
        for (ranked) |r| gpa.free(r.candidate_id);
        gpa.free(ranked);
    }
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    // C 更短但违反硬约束：先淘汰，A 胜出
    try std.testing.expectEqualStrings("A", ranked[0].candidate_id);
    try std.testing.expect(ranked[1].eliminated);
}

test "empty outcomes" {
    const metrics = evaluate(&.{});
    try std.testing.expectEqual(@as(usize, 0), metrics.samples);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), metrics.tool_reliability, 0.0001);
}
