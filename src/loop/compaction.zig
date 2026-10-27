//! 上下文压缩：按令牌预算把最旧的工具输出压成摘要。
//!
//! 保护项不可压缩：system 提示词、终止条件、门失败记录、计划、最近 N 轮。
//! 压缩不能丢审计轨迹 —— 每条被压缩的内容都留下一条 audit 条目（轮次、原始令牌数、摘要）。
//! 如果某次压缩会让审计轨迹变短，直接判失败，而不是悄悄丢掉一条记录。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CompactionError = error{
    AuditTrailLost,
    OutOfMemory,
};

pub const Kind = enum {
    system,
    user,
    assistant,
    tool_output,
    plan,
    gate_failure,
    termination,
    audit,
};

pub fn kindFromString(s: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, s);
}

pub fn isProtectedKind(kind: Kind) bool {
    return switch (kind) {
        .system, .plan, .gate_failure, .termination, .audit => true,
        .user, .assistant, .tool_output => false,
    };
}

/// 保守估算：ceil(len/4)。不追求与某个具体 tokenizer 完全一致。
pub fn estimateTokens(text: []const u8) usize {
    return (text.len + 3) / 4;
}

pub const Item = struct {
    kind: Kind,
    turn: usize,
    content: []const u8,
};

pub const AuditEntry = struct {
    turn: usize,
    kind: Kind,
    original_tokens: usize,
    summary: []const u8,
};

pub const Result = struct {
    items: []Item,
    audit: []AuditEntry,
    before_tokens: usize,
    after_tokens: usize,
    compacted_count: usize,
    protected_kept: usize,

    pub fn free(self: *const Result, gpa: Allocator) void {
        for (self.items) |it| gpa.free(it.content);
        gpa.free(self.items);
        for (self.audit) |a| gpa.free(a.summary);
        gpa.free(self.audit);
    }
};

/// 抽取式摘要：第一个非空行 + 最多三个数字事实。不调用模型，结果可复现。
pub fn summarize(gpa: Allocator, text: []const u8, max_chars: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(
        gpa,
    );

    var lines = std.mem.splitAny(u8, text, "\n");
    const first = lines.next() orelse "";
    const head = std.mem.trim(u8, first, " \t");
    if (head.len > 0) try out.appendSlice(gpa, head);

    var found: usize = 0;
    var i: usize = 0;
    while (i < text.len and found < 3) {
        if (!(text[i] >= '0' and text[i] <= '9')) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.')) i += 1;
        if (i == start) {
            i += 1;
            continue;
        }
        if (found > 0 or head.len > 0) try out.appendSlice(gpa, " ");
        try out.appendSlice(gpa, text[start..i]);
        found += 1;
    }

    const full = try out.toOwnedSlice(
        gpa,
    );
    if (full.len <= max_chars) return full;
    const trimmed = try gpa.dupe(u8, full[0..max_chars]);
    gpa.free(full);
    return trimmed;
}

pub const Compaction = struct {
    gpa: Allocator,
    budget_tokens: usize,
    protected_last_n: usize,
    max_summary_chars: usize,

    pub fn init(gpa: Allocator, budget_tokens: usize, protected_last_n: usize) Compaction {
        return .{
            .gpa = gpa,
            .budget_tokens = budget_tokens,
            .protected_last_n = protected_last_n,
            .max_summary_chars = 200,
        };
    }

    fn protected(self: *const Compaction, item: Item, max_turn: usize) bool {
        if (isProtectedKind(item.kind)) return true;
        if (self.protected_last_n == 0) return false;
        return item.turn + self.protected_last_n > max_turn;
    }

    pub fn compact(self: *const Compaction, source: []const Item) !Result {
        const gpa = self.gpa;

        var items: std.ArrayList(Item) = .empty;
        errdefer {
            for (items.items) |it| gpa.free(it.content);
            items.deinit(
                gpa,
            );
        }
        for (source) |it| try items.append(gpa, .{ .kind = it.kind, .turn = it.turn, .content = try gpa.dupe(u8, it.content) });

        var audit: std.ArrayList(AuditEntry) = .empty;
        errdefer {
            for (audit.items) |a| gpa.free(a.summary);
            audit.deinit(
                gpa,
            );
        }

        var max_turn: usize = 0;
        for (items.items) |it| max_turn = @max(max_turn, it.turn);

        var before: usize = 0;
        for (items.items) |it| before += estimateTokens(it.content);

        var protected_kept: usize = 0;
        for (items.items) |it| {
            if (self.protected(it, max_turn)) protected_kept += 1;
        }

        var total: usize = before;
        var compacted: usize = 0;

        // 每轮压掉最旧的一条可压缩内容；最多 items.len 次，避免无界循环。
        var guard: usize = 0;
        while (total > self.budget_tokens and guard < items.items.len) {
            guard += 1;

            var pick: ?usize = null;
            var summary: []const u8 = "";
            for (items.items, 0..) |it, idx| {
                if (self.protected(it, max_turn)) continue;
                const candidate = try summarize(gpa, it.content, self.max_summary_chars);
                // 压不动就跳过：摘要不比原文短，压缩就没有意义。
                if (estimateTokens(candidate) >= estimateTokens(it.content)) {
                    gpa.free(candidate);
                    continue;
                }
                pick = idx;
                summary = candidate;
                break;
            }
            if (pick == null) break;

            const idx = pick.?;
            const original = items.items[idx];
            try audit.append(gpa, .{
                .turn = original.turn,
                .kind = original.kind,
                .original_tokens = estimateTokens(original.content),
                .summary = try gpa.dupe(u8, summary),
            });

            gpa.free(items.items[idx].content);
            items.items[idx].content = try gpa.dupe(u8, summary);
            gpa.free(summary);
            compacted += 1;

            total = 0;
            for (items.items) |it| total += estimateTokens(it.content);
            for (audit.items) |a| total += estimateTokens(a.summary);
        }

        // 审计轨迹必须完整：被压缩的条数与留下的条目数必须一一对应。
        if (audit.items.len != compacted) return error.AuditTrailLost;

        return .{
            .items = try items.toOwnedSlice(
                gpa,
            ),
            .audit = try audit.toOwnedSlice(
                gpa,
            ),
            .before_tokens = before,
            .after_tokens = total,
            .compacted_count = compacted,
            .protected_kept = protected_kept,
        };
    }
};

test "token estimate is ceil(len/4)" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("abcde"));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("x"));
}

test "extractive summary is deterministic and capped" {
    const gpa = std.testing.allocator;
    const text = "drc report: 0 hard errors, 3 warnings\nlots and lots of filler text that goes on and on for a while";
    const s = try summarize(gpa, text, 40);
    defer gpa.free(s);
    const again = try summarize(gpa, text, 40);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(s, again);
    try std.testing.expect(s.len <= 40);
    try std.testing.expect(std.mem.indexOf(u8, s, "0") != null);
}

/// 测试用：comptime 生成确定长度的长输出（真实工具输出都比摘要长）。
fn repeat(comptime n: usize, comptime s: []const u8) [n * s.len]u8 {
    var out: [n * s.len]u8 = undefined;
    for (0..n) |i| {
        for (s, 0..) |c, j| out[i * s.len + j] = c;
    }
    return out;
}

test "compaction respects the budget and keeps protected items" {
    const gpa = std.testing.allocator;
    var c = Compaction.init(gpa, 40, 1);

    const long_a = "drc report: 0 hard errors\n" ++ comptime repeat(60, "filler ");
    const long_b = "si review: 3 warnings\n" ++ comptime repeat(40, "noise ");

    const items = [_]Item{
        .{ .kind = .system, .turn = 0, .content = "system prompt that must never be compacted at all" },
        .{ .kind = .tool_output, .turn = 1, .content = long_a },
        .{ .kind = .tool_output, .turn = 2, .content = long_b },
        .{ .kind = .termination, .turn = 3, .content = "termination criterion: drc_errors must equal zero" },
        .{ .kind = .tool_output, .turn = 4, .content = "latest tool output protected as the last turn" },
    };

    const res = try c.compact(&items);
    defer res.free(gpa);

    try std.testing.expect(res.after_tokens < res.before_tokens);
    try std.testing.expect(res.compacted_count > 0);
    try std.testing.expectEqual(res.compacted_count, res.audit.len);

    // system 与 termination 原文保留。
    try std.testing.expectEqualStrings(items[0].content, res.items[0].content);
    try std.testing.expectEqualStrings(items[3].content, res.items[3].content);
    // 最近一轮受保护。
    try std.testing.expectEqualStrings(items[4].content, res.items[4].content);
    try std.testing.expect(res.protected_kept >= 3);
}

test "audit trail cannot be dropped" {
    const gpa = std.testing.allocator;
    var c = Compaction.init(gpa, 1000, 0);

    const items = [_]Item{.{ .kind = .tool_output, .turn = 1, .content = "short output" }};
    const res = try c.compact(&items);
    defer res.free(gpa);

    // 预算充足：不压缩，也不伪造审计条目。
    try std.testing.expectEqual(@as(usize, 0), res.compacted_count);
    try std.testing.expectEqual(@as(usize, 0), res.audit.len);
    try std.testing.expectEqual(res.before_tokens, res.after_tokens);
}
