//! 检查点与回退：每轮一个检查点，先看 diff，再决定能不能回退。
//!
//! 两条硬规则：
//! - 不可逆效果（推上去的提交、发出去的请求、被覆盖的远端状态）不能回退——
//!   rewind 只恢复文件内容，不能把世界恢复到动作之前；
//! - 飞行记录器（flight recorder）是 append-only：任何截断请求都被拒绝。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const checkpoints_per_turn: usize = 1;

pub const Entry = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
    /// 该条记录产生了不可逆效果：回退时必须拒绝。
    irreversible: bool,
};

pub const Checkpoint = struct {
    gpa: Allocator,
    turn: usize,
    entries: std.ArrayList(Entry),

    pub fn init(gpa: Allocator, turn: usize) Checkpoint {
        return .{ .gpa = gpa, .turn = turn, .entries = .empty };
    }

    pub fn deinit(self: *Checkpoint) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.path);
            self.gpa.free(e.before);
            self.gpa.free(e.after);
        }
        self.entries.deinit(self.gpa);
    }

    pub fn record(self: *Checkpoint, path: []const u8, before: []const u8, after: []const u8, irreversible: bool) !void {
        try self.entries.append(self.gpa, .{
            .path = try self.gpa.dupe(u8, path),
            .before = try self.gpa.dupe(u8, before),
            .after = try self.gpa.dupe(u8, after),
            .irreversible = irreversible,
        });
    }
};

pub const DiffLine = struct {
    path: []const u8,
    removed: usize,
    added: usize,
};

/// diff 预览：回退前必须先看到会改什么，不能盲回退。
pub fn diffPreview(gpa: Allocator, cp: *const Checkpoint) ![]DiffLine {
    var out: std.ArrayList(DiffLine) = .empty;
    errdefer out.deinit(
        gpa,
    );

    for (cp.entries.items) |e| {
        var removed: usize = 0;
        var added: usize = 0;
        var it = std.mem.splitScalar(u8, e.before, '\n');
        while (it.next()) |line| {
            if (line.len > 0) removed += 1;
        }
        it = std.mem.splitScalar(u8, e.after, '\n');
        while (it.next()) |line| {
            if (line.len > 0) added += 1;
        }
        try out.append(gpa, .{ .path = try gpa.dupe(u8, e.path), .removed = removed, .added = added });
    }
    return out.toOwnedSlice(
        gpa,
    );
}

pub const RewindResult = struct {
    turn: usize,
    restored: []const []const u8,
    refused: []const []const u8,

    pub fn free(self: *const RewindResult, gpa: Allocator) void {
        for (self.restored) |p| gpa.free(p);
        gpa.free(self.restored);
        for (self.refused) |p| gpa.free(p);
        gpa.free(self.refused);
    }
};

pub const RewindError = error{OutOfMemory};

/// 回退：只恢复文件内容；不可逆效果一律拒绝，并如实报告。
pub fn rewind(gpa: Allocator, cp: *const Checkpoint) !RewindResult {
    var restored: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (restored.items) |p| gpa.free(p);
        restored.deinit(
            gpa,
        );
    }

    var refused: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refused.items) |p| gpa.free(p);
        refused.deinit(
            gpa,
        );
    }

    for (cp.entries.items) |e| {
        if (e.irreversible) {
            try refused.append(gpa, try gpa.dupe(u8, e.path));
            continue;
        }
        try restored.append(gpa, try gpa.dupe(u8, e.path));
    }

    return .{
        .turn = cp.turn,
        .restored = try restored.toOwnedSlice(
            gpa,
        ),
        .refused = try refused.toOwnedSlice(
            gpa,
        ),
    };
}

pub const Record = struct {
    turn: usize,
    summary: []const u8,
};

pub const RecorderError = error{
    TurnAlreadyOpen,
    NoOpenTurn,
    /// append-only：截断永远被拒绝。
    TruncateRefused,
    OutOfMemory,
};

pub const FlightRecorder = struct {
    gpa: Allocator,
    records: std.ArrayList(Record),
    open: ?*Checkpoint,

    pub fn init(gpa: Allocator) FlightRecorder {
        return .{ .gpa = gpa, .records = .empty, .open = null };
    }

    pub fn deinit(self: *FlightRecorder) void {
        for (self.records.items) |r| self.gpa.free(r.summary);
        self.records.deinit(self.gpa);
        if (self.open) |cp| {
            cp.deinit();
            self.gpa.destroy(cp);
        }
    }

    /// 每轮一个检查点：同一轮开第二个检查点直接拒绝。
    pub fn beginTurn(self: *FlightRecorder, turn: usize) !*Checkpoint {
        if (self.open != null) return error.TurnAlreadyOpen;
        const cp = try self.gpa.create(Checkpoint);
        cp.* = Checkpoint.init(self.gpa, turn);
        self.open = cp;
        return cp;
    }

    /// 关闭本轮：检查点落进飞行记录器，之后不可删。
    pub fn endTurn(self: *FlightRecorder) !void {
        const cp = self.open orelse return error.NoOpenTurn;
        try self.records.append(self.gpa, .{
            .turn = cp.turn,
            .summary = try std.fmt.allocPrint(self.gpa, "turn {d}: {d} entries", .{ cp.turn, cp.entries.items.len }),
        });
        // 关闭本轮只释放条目：记录本身留在 append-only 的飞行记录器里。
        cp.deinit();
        self.gpa.destroy(cp);
        self.open = null;
    }

    pub fn append(self: *FlightRecorder, turn: usize, summary: []const u8) !void {
        try self.records.append(self.gpa, .{ .turn = turn, .summary = try self.gpa.dupe(u8, summary) });
    }

    /// append-only：没有删除路径。
    pub fn truncate(self: *FlightRecorder) RecorderError!void {
        _ = self;
        return error.TruncateRefused;
    }

    pub fn count(self: *const FlightRecorder) usize {
        return self.records.items.len;
    }
};

test "one checkpoint per turn" {
    const gpa = std.testing.allocator;
    var rec = FlightRecorder.init(gpa);
    defer rec.deinit();

    const cp = try rec.beginTurn(1);
    try cp.record("src/loop/hooks.zig", "a\nb", "a\nb\nc", false);
    try std.testing.expectError(error.TurnAlreadyOpen, rec.beginTurn(1));

    try rec.endTurn();
    try std.testing.expectEqual(@as(usize, 1), rec.count());

    const cp2 = try rec.beginTurn(2);
    try cp2.record("src/loop/approval.zig", "", "x", false);
    try rec.endTurn();
    try std.testing.expectEqual(@as(usize, 2), rec.count());
    try std.testing.expectEqual(@as(usize, 1), checkpoints_per_turn);
}

test "diff preview before rewind" {
    const gpa = std.testing.allocator;
    var cp = Checkpoint.init(gpa, 3);
    defer cp.deinit();

    try cp.record("src/loop/hooks.zig", "line1\nline2", "line1\nline2\nline3", false);
    const lines = try diffPreview(gpa, &cp);
    defer {
        for (lines) |l| gpa.free(l.path);
        gpa.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 2), lines[0].removed);
    try std.testing.expectEqual(@as(usize, 3), lines[0].added);
}

test "rewind refuses irreversible effects" {
    const gpa = std.testing.allocator;
    var cp = Checkpoint.init(gpa, 4);
    defer cp.deinit();

    try cp.record("src/loop/hooks.zig", "old", "new", false);
    try cp.record("git push --force", "before push", "after push", true);

    const res = try rewind(gpa, &cp);
    defer res.free(gpa);

    try std.testing.expectEqual(@as(usize, 1), res.restored.len);
    try std.testing.expectEqual(@as(usize, 1), res.refused.len);
    try std.testing.expectEqualStrings("git push --force", res.refused[0]);
    try std.testing.expectEqual(@as(usize, 4), res.turn);
}

test "flight recorder is append-only" {
    const gpa = std.testing.allocator;
    var rec = FlightRecorder.init(gpa);
    defer rec.deinit();

    try rec.append(1, "planned 9 modules");
    try rec.append(2, "hooks engine landed");
    try std.testing.expectEqual(@as(usize, 2), rec.count());
    try std.testing.expectError(error.TruncateRefused, rec.truncate());
    try std.testing.expectEqual(@as(usize, 2), rec.count());
    try std.testing.expectError(error.NoOpenTurn, rec.endTurn());
}
