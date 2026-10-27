//! 计划层：plan mode 只读、任务状态机、崩溃可恢复的 markdown 计划文件。
//!
//! 规则：
//! - plan mode 只读：不允许写文件，也不允许执行工具改动；
//! - blocked 必须同一条件连续出现满 3 次才能标记；条件变了就重新计数（重新审计）；
//! - 有未关闭任务时不能把整体标记为完成；
//! - 计划文件先写 .tmp 再 rename：崩溃时不会留下半截计划。

const std = @import("std");
const ioc = @import("ioctx");
const Allocator = std.mem.Allocator;

pub const blocked_threshold: usize = 3;

pub const Mode = enum { plan, execute };

pub const Status = enum { pending, in_progress, completed, blocked };

pub fn modeFromString(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "plan")) return .plan;
    if (std.mem.eql(u8, s, "execute")) return .execute;
    return null;
}

pub fn statusFromString(s: []const u8) ?Status {
    if (std.mem.eql(u8, s, "pending")) return .pending;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, s, "completed")) return .completed;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    return null;
}

pub const Task = struct {
    id: []const u8,
    title: []const u8,
    status: Status,
    blocked_condition: []const u8,
    /// 同一条件连续出现的次数。
    blocked_turns: usize,
};

pub const PlanError = error{
    TaskNotFound,
    ReadOnlyPlanMode,
    OpenTasksRemain,
    OutOfMemory,
};

pub const Plan = struct {
    gpa: Allocator,
    mode: Mode,
    goal: []const u8,
    tasks: std.ArrayList(Task),
    budget_tokens: usize,
    used_tokens: usize,

    /// goal 必须持有堆上副本：deinit 释放调用方传入的字符串字面量会破坏只读段。
    pub fn init(gpa: Allocator, goal: []const u8, mode: Mode, budget_tokens: usize) !Plan {
        return .{
            .gpa = gpa,
            .mode = mode,
            .goal = try gpa.dupe(u8, goal),
            .tasks = .empty,
            .budget_tokens = budget_tokens,
            .used_tokens = 0,
        };
    }

    pub fn deinit(self: *Plan) void {
        for (self.tasks.items) |t| {
            self.gpa.free(t.id);
            self.gpa.free(t.title);
            self.gpa.free(t.blocked_condition);
        }
        self.tasks.deinit(self.gpa);
        self.gpa.free(self.goal);
    }

    pub fn addTask(self: *Plan, id: []const u8, title: []const u8) !void {
        try self.tasks.append(self.gpa, .{
            .id = try self.gpa.dupe(u8, id),
            .title = try self.gpa.dupe(u8, title),
            .status = .pending,
            .blocked_condition = "",
            .blocked_turns = 0,
        });
    }

    /// 必须返回数组里的真实元素：返回循环变量的副本会让状态写入落在副本上。
    pub fn find(self: *const Plan, id: []const u8) ?*Task {
        for (self.tasks.items, 0..) |_, i| {
            const t = &self.tasks.items[i];
            if (std.mem.eql(u8, t.id, id)) return @constCast(t);
        }
        return null;
    }

    pub fn openCount(self: *const Plan) usize {
        var n: usize = 0;
        for (self.tasks.items) |t| {
            if (t.status != .completed) n += 1;
        }
        return n;
    }

    /// 有未关闭任务就不能判完成。
    pub fn canComplete(self: *const Plan) bool {
        return self.openCount() == 0;
    }

    /// plan mode 只读。
    pub fn allowsWrite(self: *const Plan) bool {
        return self.mode == .execute;
    }

    /// 返回是否真的达到 blocked 门槛：同一条件连续满 3 次才算。
    pub fn markBlocked(self: *Plan, id: []const u8, condition: []const u8) !bool {
        const t = self.find(id) orelse return error.TaskNotFound;

        if (t.blocked_turns == 0 or std.mem.eql(u8, t.blocked_condition, condition)) {
            if (t.blocked_turns == 0) t.blocked_condition = try self.gpa.dupe(u8, condition);
            t.blocked_turns += 1;
        } else {
            // 条件变了：重新计数，之前的连续次数不作数。
            self.gpa.free(t.blocked_condition);
            t.blocked_condition = try self.gpa.dupe(u8, condition);
            t.blocked_turns = 1;
        }

        if (t.blocked_turns >= blocked_threshold) {
            t.status = .blocked;
            return true;
        }
        return false;
    }

    pub fn recordUsage(self: *Plan, tokens: usize) void {
        self.used_tokens += tokens;
    }

    pub fn budgetExhausted(self: *const Plan) bool {
        if (self.budget_tokens == 0) return false;
        return self.used_tokens >= self.budget_tokens;
    }

    pub fn renderMarkdown(self: *const Plan) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(
            self.gpa,
        );

        try out.appendSlice(self.gpa, "# Plan: ");
        try out.appendSlice(self.gpa, self.goal);
        try out.appendSlice(self.gpa, "\nmode: ");
        try out.appendSlice(self.gpa, if (self.mode == .plan) "plan (read-only)" else "execute");
        try out.appendSlice(self.gpa, "\nbudget: ");
        const budget_line = try std.fmt.allocPrint(self.gpa, "{d} tokens, used {d}\n\n", .{ self.budget_tokens, self.used_tokens });
        defer self.gpa.free(budget_line);
        try out.appendSlice(self.gpa, budget_line);

        for (self.tasks.items) |t| {
            const box = if (t.status == .completed) "[x]" else "[ ]";
            const line = try std.fmt.allocPrint(self.gpa, "- {s} {s} {s} ({s})", .{ box, t.id, t.title, @tagName(t.status) });
            defer self.gpa.free(line);
            try out.appendSlice(self.gpa, line);
            if (t.status == .blocked) {
                const detail = try std.fmt.allocPrint(self.gpa, "  condition: {s} (consecutive {d})", .{ t.blocked_condition, t.blocked_turns });
                defer self.gpa.free(detail);
                try out.appendSlice(self.gpa, detail);
            }
            try out.appendSlice(self.gpa, "\n");
        }

        return out.toOwnedSlice(
            self.gpa,
        );
    }

    /// 崩溃可恢复：先写临时文件，再 rename。半截计划不会顶替上一份完整计划。
    pub fn writeMarkdown(self: *const Plan, dir: ioc.Dir) ![]const u8 {
        const text = try self.renderMarkdown();
        defer self.gpa.free(text);

        const tmp_name = try std.fmt.allocPrint(self.gpa, "plan.md.tmp.{s}", .{self.goal});
        defer self.gpa.free(tmp_name);

        var f = try dir.createFile(tmp_name, .{ .exclusive = true });
        defer f.close();
        try f.writeAll(text);

        const final_name = "plan.md";
        dir.rename(tmp_name, final_name) catch |e| {
            dir.deleteFile(tmp_name) catch {};
            return e;
        };
        return self.gpa.dupe(u8, final_name);
    }
};

test "plan mode is read-only" {
    const gpa = std.testing.allocator;
    var p = try Plan.init(gpa, "loop modules", .plan, 1000);
    defer p.deinit();

    try std.testing.expect(!p.allowsWrite());

    var e = try Plan.init(gpa, "loop modules", .execute, 1000);
    defer e.deinit();
    try std.testing.expect(e.allowsWrite());
}

test "blocked requires the same condition three consecutive times" {
    const gpa = std.testing.allocator;
    var p = try Plan.init(gpa, "goal", .execute, 0);
    defer p.deinit();

    try p.addTask("t1", "write hooks");

    try std.testing.expect(!(try p.markBlocked("t1", "test API unreachable")));
    try std.testing.expect(!(try p.markBlocked("t1", "test API unreachable")));
    try std.testing.expect(try p.markBlocked("t1", "test API unreachable"));
    try std.testing.expectEqual(Status.blocked, p.find("t1").?.status);

    // 条件变了：重新计数，之前的连续次数不作数。
    var p2 = try Plan.init(gpa, "goal", .execute, 0);
    defer p2.deinit();
    try p2.addTask("t2", "write tests");
    try std.testing.expect(!(try p2.markBlocked("t2", "zig version mismatch")));
    try std.testing.expect(!(try p2.markBlocked("t2", "zig version mismatch")));
    try std.testing.expect(!(try p2.markBlocked("t2", "network blocked")));
    try std.testing.expectEqual(@as(usize, 1), p2.find("t2").?.blocked_turns);
    try std.testing.expectEqual(Status.pending, p2.find("t2").?.status);
}

test "cannot complete while open tasks remain" {
    const gpa = std.testing.allocator;
    var p = try Plan.init(gpa, "goal", .execute, 0);
    defer p.deinit();

    try p.addTask("t1", "a");
    try p.addTask("t2", "b");
    try std.testing.expectEqual(@as(usize, 2), p.openCount());
    try std.testing.expect(!p.canComplete());

    p.find("t1").?.status = .completed;
    try std.testing.expect(!p.canComplete());

    p.find("t2").?.status = .completed;
    try std.testing.expect(p.canComplete());
}

test "goal budget tracks usage" {
    const gpa = std.testing.allocator;
    var p = try Plan.init(gpa, "goal", .execute, 100);
    defer p.deinit();

    try std.testing.expect(!p.budgetExhausted());
    p.recordUsage(60);
    try std.testing.expect(!p.budgetExhausted());
    p.recordUsage(40);
    try std.testing.expect(p.budgetExhausted());
}

test "plan file is crash-proof: tmp then rename" {
    const gpa = std.testing.allocator;
    var p = try Plan.init(gpa, "loop", .plan, 1000);
    defer p.deinit();
    try p.addTask("t1", "hooks");

    const dir = ioc.cwd();
    dir.makeDir(".cuteclaw-plan-test") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var opened = try dir.openDir(".cuteclaw-plan-test", .{ .iterate = true });

    const written = try p.writeMarkdown(opened);
    defer gpa.free(written);

    // 没有 .tmp 残留：rename 成功即意味着文件是完整的。
    var it = opened.iterate();
    var leftovers: usize = 0;
    while (try it.next()) |e| {
        if (std.mem.indexOf(u8, e.name, ".tmp") != null) leftovers += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), leftovers);

    const text = try opened.readFileAlloc(gpa, "plan.md", 64 * 1024);
    defer gpa.free(text);
    const expected = try p.renderMarkdown();
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expect(std.mem.indexOf(u8, text, "plan (read-only)") != null);

    opened.deleteFile("plan.md") catch {};
    dir.deleteDir(".cuteclaw-plan-test") catch {};
}

test "status parsing" {
    try std.testing.expectEqual(Status.in_progress, statusFromString("in_progress").?);
    try std.testing.expect(statusFromString("nope") == null);
}
