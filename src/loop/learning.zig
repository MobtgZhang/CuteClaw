//! 学习回路（对齐 Hermes Agent 的闭环）：轨迹捕获与压缩、复杂任务后自主起草技能、
//! 技能自我改进计数器、确定性的会话倒排索引检索、周期性 nudge。
//!
//! 硬约束：guardrails 不可被学习回路改写。任何写入 guardrail 前缀的请求都被拒绝，
//! 否则自进化就能通过"学习"拿到它本来没有的权限。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const complex_threshold: usize = 6;
pub const recurring_threshold: usize = 3;

pub const LearningError = error{
    GuardrailWriteRefused,
    OutOfMemory,
};

/// 学习回路永远不能改写 guardrails。
pub const guardrails_immutable = true;

pub const Step = struct {
    turn: usize,
    tool: []const u8,
    args: []const u8,
    ok: bool,
    /// 该步是被纠正后才成立的：这是"值得写进技能"的信号。
    correction: bool,
};

pub const Trajectory = struct {
    gpa: Allocator,
    steps: std.ArrayList(Step),

    pub fn init(gpa: Allocator) Trajectory {
        return .{ .gpa = gpa, .steps = .empty };
    }

    pub fn deinit(self: *Trajectory) void {
        for (self.steps.items) |s| {
            self.gpa.free(s.tool);
            self.gpa.free(s.args);
        }
        self.steps.deinit(self.gpa);
    }

    pub fn record(self: *Trajectory, turn: usize, tool: []const u8, args: []const u8, ok: bool, correction: bool) !void {
        try self.steps.append(self.gpa, .{
            .turn = turn,
            .tool = try self.gpa.dupe(u8, tool),
            .args = try self.gpa.dupe(u8, args),
            .ok = ok,
            .correction = correction,
        });
    }
};

pub const Compressed = struct {
    kept_first: usize,
    kept_last: usize,
    kept_errors: usize,
    total: usize,
    text: []const u8,

    pub fn free(self: *const Compressed, gpa: Allocator) void {
        gpa.free(self.text);
    }
};

/// 轨迹压缩：保留开头、结尾与所有出错/被纠正的步骤。不调用模型，结果可复现。
pub fn compressTrajectory(gpa: Allocator, t: *const Trajectory, keep_first: usize, keep_last: usize) !Compressed {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(
        gpa,
    );

    var kept_first: usize = 0;
    var kept_last: usize = 0;
    var kept_errors: usize = 0;

    for (t.steps.items, 0..) |s, i| {
        const is_first = i < keep_first;
        const is_last = i >= t.steps.items.len - keep_last;
        const is_error = !s.ok or s.correction;
        if (!is_first and !is_last and !is_error) continue;

        if (is_first) kept_first += 1;
        if (is_last) kept_last += 1;
        if (is_error) kept_errors += 1;

        const line = try std.fmt.allocPrint(gpa, "{d} {s} {s}\n", .{ s.turn, s.tool, s.args });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }

    return .{
        .kept_first = kept_first,
        .kept_last = kept_last,
        .kept_errors = kept_errors,
        .total = t.steps.items.len,
        .text = try out.toOwnedSlice(
            gpa,
        ),
    };
}

/// 复杂任务 = 步数够多 + 至少一次被纠正 + 某个工具反复出现。三者缺一不可。
pub fn shouldCreateSkill(t: *const Trajectory) !bool {
    if (t.steps.items.len < complex_threshold) return false;

    var corrections: usize = 0;
    for (t.steps.items) |s| {
        if (s.correction) corrections += 1;
    }
    if (corrections == 0) return false;

    var counts = std.StringHashMap(usize).init(t.gpa);
    defer {
        var kit = counts.iterator();
        while (kit.next()) |e| t.gpa.free(e.key_ptr.*);
        counts.deinit();
    }
    for (t.steps.items) |s| {
        const entry = try counts.getOrPut(s.tool);
        if (!entry.found_existing) {
            entry.key_ptr.* = try t.gpa.dupe(u8, s.tool);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* >= recurring_threshold) return true;
    }
    return false;
}

pub const SkillDraft = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,

    pub fn free(self: *const SkillDraft, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.body);
    }
};

fn normalizeName(gpa: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(
        gpa,
    );
    for (raw) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            try out.append(gpa, c);
        } else if (c == '_' or c == ' ') {
            try out.append(gpa, '-');
        }
    }
    return out.toOwnedSlice(
        gpa,
    );
}

/// 自主起草技能：名字来自反复出现的工具，正文来自被纠正的那几步。
pub fn draftSkill(gpa: Allocator, t: *const Trajectory) !SkillDraft {
    var counts = std.StringHashMap(usize).init(gpa);
    defer {
        var kit = counts.iterator();
        while (kit.next()) |e| gpa.free(e.key_ptr.*);
        counts.deinit();
    }
    for (t.steps.items) |s| {
        const entry = try counts.getOrPut(s.tool);
        if (!entry.found_existing) {
            entry.key_ptr.* = try gpa.dupe(u8, s.tool);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* > best_count) {
            best_count = e.value_ptr.*;
            best = e.key_ptr.*;
        }
    }

    const tool = best orelse "skill";
    const name = try normalizeName(gpa, tool);
    errdefer gpa.free(name);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(
        gpa,
    );
    try body.appendSlice(gpa, "## Steps\n");
    for (t.steps.items) |s| {
        if (s.correction) {
            const line = try std.fmt.allocPrint(gpa, "- {s} {s}（此处必须按本条修正执行）\n", .{ s.tool, s.args });
            defer gpa.free(line);
            try body.appendSlice(gpa, line);
        }
    }

    const description = try std.fmt.allocPrint(gpa, "从 {d} 步会话轨迹中提炼，含 {d} 次纠正", .{ t.steps.items.len, blk: {
        var n: usize = 0;
        for (t.steps.items) |s| {
            if (s.correction) n += 1;
        }
        break :blk n;
    } });

    return .{
        .name = name,
        .description = description,
        .body = try body.toOwnedSlice(
            gpa,
        ),
    };
}

pub const Counters = struct {
    uses: usize = 0,
    ok: usize = 0,
    fail: usize = 0,
    improvements: usize = 0,

    pub fn record(self: *Counters, success: bool) void {
        self.uses += 1;
        if (success) self.ok += 1 else self.fail += 1;
    }

    /// 技能在使用中自我改进：只有失败后改好才算改进，成功本身不算。
    pub fn improved(self: *Counters) void {
        if (self.fail > 0) self.improvements += 1;
    }

    pub fn passRate(self: *const Counters) f64 {
        if (self.uses == 0) return 0;
        return @as(f64, @floatFromInt(self.ok)) / @as(f64, @floatFromInt(self.uses));
    }
};

/// 确定性倒排索引：同一个输入永远得到同一个结果，不依赖模型。
pub const SearchIndex = struct {
    gpa: Allocator,
    postings: std.StringHashMap(std.ArrayList(usize)),
    docs: std.ArrayList([]const u8),

    pub fn init(gpa: Allocator) SearchIndex {
        return .{
            .gpa = gpa,
            .postings = std.StringHashMap(std.ArrayList(usize)).init(gpa),
            .docs = .empty,
        };
    }

    pub fn deinit(self: *SearchIndex) void {
        var it = self.postings.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.postings.deinit();
        for (self.docs.items) |d| self.gpa.free(d);
        self.docs.deinit(self.gpa);
    }

    pub fn addDocument(self: *SearchIndex, text: []const u8) !usize {
        const id = self.docs.items.len;
        try self.docs.append(self.gpa, try self.gpa.dupe(u8, text));

        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(
            self.gpa,
        );

        var it = std.mem.splitAny(u8, text, " \t\n.,()[]{}:;/");
        while (it.next()) |w| {
            if (w.len < 3) continue;
            const lower = try std.ascii.allocLowerString(self.gpa, w);
            try words.append(self.gpa, lower);
        }
        defer {
            for (words.items) |w| self.gpa.free(w);
        }

        for (words.items) |w| {
            const entry = try self.postings.getOrPut(w);
            if (!entry.found_existing) {
                entry.key_ptr.* = try self.gpa.dupe(u8, w);
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.gpa, id);
        }
        return id;
    }

    /// 多词查询取交集：结果按文档 id 升序，可复现。
    pub fn search(self: *const SearchIndex, query: []const u8) ![]usize {
        const gpa = self.gpa;
        var terms: std.ArrayList([]const u8) = .empty;
        defer terms.deinit(
            gpa,
        );

        var it = std.mem.splitAny(u8, query, " \t\n.,()[]{}:;/");
        while (it.next()) |w| {
            if (w.len < 3) continue;
            try terms.append(gpa, try std.ascii.allocLowerString(gpa, w));
        }
        defer {
            for (terms.items) |t| gpa.free(t);
        }

        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(
            gpa,
        );

        for (self.docs.items, 0..) |_, id| {
            var all = true;
            for (terms.items) |t| {
                const list = self.postings.get(t) orelse {
                    all = false;
                    break;
                };
                var found = false;
                for (list.items) |doc| {
                    if (doc == id) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    all = false;
                    break;
                }
            }
            if (all) try out.append(gpa, id);
        }
        return out.toOwnedSlice(
            gpa,
        );
    }
};

pub const Nudge = struct {
    every_turns: usize,

    pub fn init(every_turns: usize) Nudge {
        return .{ .every_turns = every_turns };
    }

    pub fn due(self: *const Nudge, turn: usize) bool {
        if (self.every_turns == 0) return false;
        return turn > 0 and turn % self.every_turns == 0;
    }
};

pub const Learning = struct {
    gpa: Allocator,
    guardrail_prefixes: []const []const u8,

    pub fn init(gpa: Allocator, guardrail_prefixes: []const []const u8) Learning {
        return .{ .gpa = gpa, .guardrail_prefixes = guardrail_prefixes };
    }

    /// guardrails 不可被学习回路改写。
    pub fn checkWrite(self: *const Learning, path: []const u8) LearningError!void {
        for (self.guardrail_prefixes) |p| {
            if (std.mem.startsWith(u8, path, p)) return error.GuardrailWriteRefused;
        }
    }
};

test "trajectory compression keeps first, last and every error" {
    const gpa = std.testing.allocator;
    var t = Trajectory.init(gpa);
    defer t.deinit();

    try t.record(1, "graph_plan", "{}", true, false);
    try t.record(2, "graph_run", "{}", false, true);
    try t.record(3, "graph_plan", "{}", true, false);
    try t.record(4, "graph_plan", "{}", true, false);
    try t.record(5, "graph_plan", "{}", true, false);
    try t.record(6, "graph_gate", "{}", true, false);

    const c = try compressTrajectory(gpa, &t, 1, 1);
    defer c.free(gpa);
    try std.testing.expectEqual(@as(usize, 6), c.total);
    try std.testing.expectEqual(@as(usize, 1), c.kept_first);
    try std.testing.expectEqual(@as(usize, 1), c.kept_last);
    try std.testing.expectEqual(@as(usize, 1), c.kept_errors);
    try std.testing.expect(std.mem.indexOf(u8, c.text, "graph_gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.text, "graph_run") != null);
}

test "skill creation needs complexity, a correction and a recurring tool" {
    const gpa = std.testing.allocator;

    var short = Trajectory.init(gpa);
    defer short.deinit();
    try short.record(1, "graph_plan", "{}", true, true);
    try short.record(2, "graph_plan", "{}", true, true);
    try std.testing.expect(!(try shouldCreateSkill(&short)));

    var no_correction = Trajectory.init(gpa);
    defer no_correction.deinit();
    for (0..7) |i| try no_correction.record(i, "graph_plan", "{}", true, false);
    try std.testing.expect(!(try shouldCreateSkill(&no_correction)));

    var complex = Trajectory.init(gpa);
    defer complex.deinit();
    for (0..4) |i| try complex.record(i, "graph_plan", "{}", true, false);
    try complex.record(4, "graph_gate", "{\"drc\":1}", false, true);
    try complex.record(5, "graph_plan", "{}", true, false);
    try complex.record(6, "graph_plan", "{}", true, false);
    try std.testing.expect(try shouldCreateSkill(&complex));

    const draft = try draftSkill(gpa, &complex);
    defer draft.free(gpa);
    try std.testing.expectEqualStrings("graph-plan", draft.name);
    try std.testing.expect(std.mem.indexOf(u8, draft.body, "graph_gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.description, "1") != null);
}

test "skill counters track self-improvement" {
    var c = Counters{};
    c.record(true);
    c.record(false);
    try std.testing.expectEqual(@as(usize, 2), c.uses);
    try std.testing.expectEqual(@as(usize, 0), c.improvements);
    c.improved();
    try std.testing.expectEqual(@as(usize, 1), c.improvements);
    try std.testing.expectEqual(@as(f64, 0.5), c.passRate());
}

test "inverted index search is deterministic" {
    const gpa = std.testing.allocator;
    var idx = SearchIndex.init(gpa);
    defer idx.deinit();

    const a = try idx.addDocument("drc report: zero hard errors on the board");
    const b = try idx.addDocument("tolerance stackup across three features");
    const c = try idx.addDocument("drc report for the enclosure only");

    const hits = try idx.search("drc report");
    defer gpa.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(a, hits[0]);
    try std.testing.expectEqual(c, hits[1]);

    const none = try idx.search("drc stackup");
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const again = try idx.search("drc report");
    defer gpa.free(again);

    const first_key = try std.fmt.allocPrint(gpa, "{d},{d}", .{ hits[0], hits[1] });
    defer gpa.free(first_key);
    const second_key = try std.fmt.allocPrint(gpa, "{d},{d}", .{ again[0], again[1] });
    defer gpa.free(second_key);
    try std.testing.expectEqualStrings(first_key, second_key);
    _ = b;
}

test "periodic nudges and immutable guardrails" {
    const gpa = std.testing.allocator;
    const n = Nudge.init(5);
    try std.testing.expect(!n.due(4));
    try std.testing.expect(n.due(5));
    try std.testing.expect(n.due(10));
    try std.testing.expect(!n.due(0));

    try std.testing.expect(guardrails_immutable);

    var learning = Learning.init(gpa, &.{ "src/evolution/", "src/graph/gates.zig" });
    try learning.checkWrite("src/loop/learning.zig");
    try std.testing.expectError(error.GuardrailWriteRefused, learning.checkWrite("src/graph/gates.zig"));
    try std.testing.expectError(error.GuardrailWriteRefused, learning.checkWrite("src/evolution/promotion.zig"));
}
