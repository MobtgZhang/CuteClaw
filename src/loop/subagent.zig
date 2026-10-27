//! 子代理：全新上下文、互斥写入边界、并发上限、两段式评审门。
//!
//! 四条硬约束：
//! - 子代理不继承会话历史：判断不能继承它读过的东西；
//! - 写入边界必须互斥，重叠即判冲突，冲突的任务不进派发队列；
//! - 阻塞主任务的子任务不能委派出去（主流程不能等一个被委派出去的阻塞项）；
//! - 计划评审通过前不派发，结果评审通过前不合并。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Task = struct {
    id: []const u8,
    goal: []const u8,
    /// 写入边界：文件或目录前缀。
    write_scope: []const []const u8,
    /// 该子任务是否在主任务的关键路径上。
    blocking: bool,
};

pub const Conflict = struct {
    task_a: []const u8,
    task_b: []const u8,
    path: []const u8,

    pub fn free(self: *const Conflict, gpa: Allocator) void {
        gpa.free(self.path);
    }
};

pub const Limits = struct {
    max_concurrent: usize = 4,
};

pub const ReviewStage = enum { plan_review, result_review };

pub const Review = struct {
    stage: ReviewStage,
    passed: bool,
    reason: []const u8,
};

pub const Context = struct {
    task_id: []const u8,
    /// 子代理必须为 0：任何非零都意味着继承了历史。
    inherited_messages: usize,
    prompt: []const u8,
};

pub const Result = struct {
    task_id: []const u8,
    changed_paths: []const []const u8,
    review: ?Review,
};

pub const Aggregated = struct {
    results: []Result,
    changed_paths: []const []const u8,
    excluded: []const []const u8,
    fresh_context: bool,

    pub fn free(self: *const Aggregated, gpa: Allocator) void {
        gpa.free(self.results);
        for (self.changed_paths) |p| gpa.free(p);
        gpa.free(self.changed_paths);
        for (self.excluded) |p| gpa.free(p);
        gpa.free(self.excluded);
    }
};

/// 写入边界重叠：同一个文件，或一方是另一方的目录前缀。
pub fn scopesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.startsWith(u8, a, b)) return true;
    if (std.mem.startsWith(u8, b, a)) return true;
    return false;
}

pub fn detectConflicts(gpa: Allocator, tasks: []const Task) ![]Conflict {
    var out: std.ArrayList(Conflict) = .empty;
    errdefer {
        for (out.items) |c| c.free(gpa);
        out.deinit(
            gpa,
        );
    }

    var i: usize = 0;
    while (i < tasks.len) {
        var j: usize = i + 1;
        while (j < tasks.len) {
            for (tasks[i].write_scope) |sa| {
                for (tasks[j].write_scope) |sb| {
                    if (scopesOverlap(sa, sb)) {
                        try out.append(gpa, .{
                            .task_a = tasks[i].id,
                            .task_b = tasks[j].id,
                            .path = try gpa.dupe(u8, sa),
                        });
                    }
                }
            }
            j += 1;
        }
        i += 1;
    }
    return out.toOwnedSlice(
        gpa,
    );
}

/// 阻塞主任务的工作不能委派：委派出去就等于把关键路径交给一个正在等的子代理。
pub fn canDelegate(task: Task) bool {
    return !task.blocking;
}

/// 全新上下文：只带任务目标，不带任何历史。
pub fn freshContext(gpa: Allocator, task: Task) !Context {
    return .{
        .task_id = try gpa.dupe(u8, task.id),
        .inherited_messages = 0,
        .prompt = try gpa.dupe(u8, task.goal),
    };
}

pub fn dispatchable(tasks: []const Task, limits: Limits) usize {
    var n: usize = 0;
    for (tasks) |t| {
        if (!canDelegate(t)) continue;
        n += 1;
        if (n >= limits.max_concurrent) break;
    }
    return n;
}

/// 两段式门第一段：计划评审通过、无冲突、且全部可委派，才允许派发。
pub fn canDispatch(gpa: Allocator, tasks: []const Task, limits: Limits, plan_review: Review) !bool {
    if (plan_review.stage != .plan_review or !plan_review.passed) return false;

    const conflicts = try detectConflicts(gpa, tasks);
    defer {
        for (conflicts) |c| c.free(gpa);
        gpa.free(conflicts);
    }
    if (conflicts.len > 0) return false;

    for (tasks) |t| {
        if (!canDelegate(t)) return false;
    }

    // 并发上限为 0 时没有任何任务能进入派发队列。
    return dispatchable(tasks, limits) > 0;
}

/// 两段式门第二段：只有结果评审通过的结果才进聚合，其余记入 excluded。
pub fn aggregate(gpa: Allocator, results: []const Result) !Aggregated {
    var kept: std.ArrayList(Result) = .empty;
    errdefer kept.deinit(
        gpa,
    );

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(
            gpa,
        );
    }

    var excluded: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (excluded.items) |p| gpa.free(p);
        excluded.deinit(
            gpa,
        );
    }

    for (results) |r| {
        const review = r.review orelse {
            try excluded.append(gpa, try gpa.dupe(u8, r.task_id));
            continue;
        };
        if (review.stage != .result_review or !review.passed) {
            try excluded.append(gpa, try gpa.dupe(u8, r.task_id));
            continue;
        }
        try kept.append(gpa, r);
        for (r.changed_paths) |p| try paths.append(gpa, try gpa.dupe(u8, p));
    }

    return .{
        .results = try kept.toOwnedSlice(
            gpa,
        ),
        .changed_paths = try paths.toOwnedSlice(
            gpa,
        ),
        .excluded = try excluded.toOwnedSlice(
            gpa,
        ),
        .fresh_context = true,
    };
}

test "write scopes must be disjoint" {
    const gpa = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "a", .goal = "g", .write_scope = &.{"src/loop/hooks.zig"}, .blocking = false },
        .{ .id = "b", .goal = "g", .write_scope = &.{"src/loop/hooks.zig"}, .blocking = false },
        .{ .id = "c", .goal = "g", .write_scope = &.{"src/loop/compaction.zig"}, .blocking = false },
    };

    const conflicts = try detectConflicts(gpa, &tasks);
    defer {
        for (conflicts) |c| c.free(gpa);
        gpa.free(conflicts);
    }
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqualStrings("a", conflicts[0].task_a);
    try std.testing.expectEqualStrings("b", conflicts[0].task_b);

    try std.testing.expect(scopesOverlap("src/loop", "src/loop/hooks.zig"));
    try std.testing.expect(!scopesOverlap("src/loop", "src/graph"));
}

test "blocking work is not delegated" {
    const blocking = Task{ .id = "a", .goal = "g", .write_scope = &.{"src/a.zig"}, .blocking = true };
    const sidecar = Task{ .id = "b", .goal = "g", .write_scope = &.{"src/b.zig"}, .blocking = false };

    try std.testing.expect(!canDelegate(blocking));
    try std.testing.expect(canDelegate(sidecar));

    const tasks = [_]Task{ blocking, sidecar };
    try std.testing.expectEqual(@as(usize, 1), dispatchable(&tasks, .{ .max_concurrent = 4 }));
    try std.testing.expectEqual(@as(usize, 1), dispatchable(&tasks, .{ .max_concurrent = 1 }));
}

test "subagents get no inherited history" {
    const gpa = std.testing.allocator;
    const task = Task{ .id = "b", .goal = "add tests", .write_scope = &.{"tests/"}, .blocking = false };
    const ctx = try freshContext(gpa, task);
    defer {
        gpa.free(ctx.prompt);
        gpa.free(ctx.task_id);
    }
    try std.testing.expectEqual(@as(usize, 0), ctx.inherited_messages);
    try std.testing.expectEqualStrings("add tests", ctx.prompt);
}

test "two-stage review gates" {
    const gpa = std.testing.allocator;
    const tasks = [_]Task{.{ .id = "a", .goal = "g", .write_scope = &.{"src/a.zig"}, .blocking = false }};

    const failed_plan = Review{ .stage = .plan_review, .passed = false, .reason = "scope overlaps" };
    try std.testing.expect(!(try canDispatch(gpa, &tasks, .{ .max_concurrent = 4 }, failed_plan)));

    const ok_plan = Review{ .stage = .plan_review, .passed = true, .reason = "disjoint" };
    try std.testing.expect(try canDispatch(gpa, &tasks, .{ .max_concurrent = 4 }, ok_plan));

    const results = [_]Result{
        .{ .task_id = "a", .changed_paths = &.{"src/a.zig"}, .review = Review{ .stage = .result_review, .passed = true, .reason = "tests pass" } },
        .{ .task_id = "b", .changed_paths = &.{"src/b.zig"}, .review = null },
        .{ .task_id = "c", .changed_paths = &.{"src/c.zig"}, .review = Review{ .stage = .result_review, .passed = false, .reason = "unverified claim" } },
    };

    const agg = try aggregate(gpa, &results);
    defer agg.free(gpa);
    try std.testing.expectEqual(@as(usize, 1), agg.results.len);
    try std.testing.expectEqual(@as(usize, 2), agg.excluded.len);
    try std.testing.expectEqual(@as(usize, 1), agg.changed_paths.len);
    try std.testing.expect(agg.fresh_context);
}
