//! Hook 引擎：事件 -> 匹配器 -> 动作，退出码语义对齐 Claude Code（0 = 放行，2 = 拒绝）。
//!
//! 与 Claude Code 的差别是刻意的：hook 只能收紧决策，不能放宽决策，也不能改写硬门。
//! 任何试图放宽的 hook 结论都会被记录为 ignored_grants 并忽略 —— 否则一个插件脚本
//! 就能通过 hook 拿到它本来没有的能力。复合命令逐段检查（&&、||、;、|、换行），
//! 任一段命中拒绝模式即整条拒绝，避免 `echo ok && rm -rf` 这种绕过。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EventKind = enum {
    session_start,
    pre_tool,
    post_tool,
    stop,
    subagent_stop,
};

pub fn eventFromString(s: []const u8) ?EventKind {
    if (std.mem.eql(u8, s, "session_start")) return .session_start;
    if (std.mem.eql(u8, s, "pre_tool")) return .pre_tool;
    if (std.mem.eql(u8, s, "post_tool")) return .post_tool;
    if (std.mem.eql(u8, s, "stop")) return .stop;
    if (std.mem.eql(u8, s, "subagent_stop")) return .subagent_stop;
    return null;
}

pub const Decision = enum { pass, warn, deny };

pub fn decisionFromExitCode(code: u8) Decision {
    if (code == 0) return .pass;
    if (code == 2) return .deny;
    return .warn;
}

fn rank(d: Decision) u8 {
    return switch (d) {
        .pass => 0,
        .warn => 1,
        .deny => 2,
    };
}

/// 组合时取更严的一侧：hook 只能让结论更保守。
pub fn stricter(a: Decision, b: Decision) Decision {
    return if (rank(a) >= rank(b)) a else b;
}

/// hook 不能改写硬门：硬门的结论永远优先于 hook 的结论。
pub const hooks_can_override_gates = false;

pub const Matcher = struct {
    /// 精确名、`前缀*`、`*`，以及 `a|b` 形式的交替。
    pattern: []const u8,

    pub fn matches(self: *const Matcher, name: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.pattern, '|');
        while (it.next()) |alt| {
            if (alt.len == 0) continue;
            if (alt[alt.len - 1] == '*') {
                if (std.mem.startsWith(u8, name, alt[0 .. alt.len - 1])) return true;
                continue;
            }
            if (std.mem.eql(u8, alt, name)) return true;
        }
        return false;
    }
};

/// 复合命令拆段：逐段判断，不能整条字符串一把梭。
pub fn segments(gpa: Allocator, command: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(
            gpa,
        );
    }

    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(
        gpa,
    );

    var i: usize = 0;
    while (i < command.len) {
        const c = command[i];
        if (c == ';' or c == '\n' or c == '|' or c == '&') {
            const doubled = (c == '|' or c == '&') and i + 1 < command.len and command[i + 1] == c;
            if (cur.items.len > 0) {
                const seg = std.mem.trim(u8, cur.items, " \t");
                if (seg.len > 0) try out.append(gpa, try gpa.dupe(u8, seg));
            }
            cur.clearRetainingCapacity();
            i += if (doubled) 2 else 1;
            continue;
        }
        try cur.append(gpa, c);
        i += 1;
    }
    if (cur.items.len > 0) {
        const seg = std.mem.trim(u8, cur.items, " \t");
        if (seg.len > 0) try out.append(gpa, try gpa.dupe(u8, seg));
    }
    return out.toOwnedSlice(
        gpa,
    );
}

pub fn segmentDenied(pattern: []const u8, segment: []const u8) bool {
    const seg = std.mem.trim(u8, segment, " \t");
    if (pattern.len == 0 or seg.len == 0) return false;
    if (std.mem.startsWith(u8, seg, pattern)) return true;
    var it = std.mem.splitAny(u8, seg, " \t");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, pattern)) return true;
    }
    return false;
}

pub const Hook = struct {
    event: EventKind,
    matcher: Matcher,
    command: []const u8,
    /// 上一次执行返回的退出码：由外部执行器写入，测试里直接注入。
    code: u8 = 0,
};

pub const Evaluation = struct {
    decision: Decision,
    matched_hooks: usize,
    segments_checked: usize,
    denied_segment: []const u8,
};

pub const HookSet = struct {
    gpa: Allocator,
    hooks: std.ArrayList(Hook),
    deny_patterns: std.ArrayList([]const u8),
    /// hook 试图放宽决策的次数：只记录，不生效。
    ignored_grants: usize = 0,

    pub fn init(gpa: Allocator) HookSet {
        return .{ .gpa = gpa, .hooks = .empty, .deny_patterns = .empty };
    }

    pub fn deinit(self: *HookSet) void {
        for (self.hooks.items) |h| {
            self.gpa.free(h.matcher.pattern);
            self.gpa.free(h.command);
        }
        self.hooks.deinit(self.gpa);
        for (self.deny_patterns.items) |p| self.gpa.free(p);
        self.deny_patterns.deinit(self.gpa);
    }

    pub fn add(self: *HookSet, event: EventKind, pattern: []const u8, command: []const u8) !void {
        try self.hooks.append(self.gpa, .{
            .event = event,
            .matcher = .{ .pattern = try self.gpa.dupe(u8, pattern) },
            .command = try self.gpa.dupe(u8, command),
        });
    }

    pub fn denyPattern(self: *HookSet, pattern: []const u8) !void {
        try self.deny_patterns.append(self.gpa, try self.gpa.dupe(u8, pattern));
    }

    pub fn matching(self: *const HookSet, event: EventKind, name: []const u8) ![]Hook {
        var out: std.ArrayList(Hook) = .empty;
        errdefer out.deinit(
            self.gpa,
        );
        for (self.hooks.items) |h| {
            if (h.event != event) continue;
            if (!h.matcher.matches(name)) continue;
            try out.append(self.gpa, h);
        }
        return out.toOwnedSlice(
            self.gpa,
        );
    }

    /// 拒绝模式优先于 hook 结论：逐段检查，任一段命中即整条拒绝。
    pub fn evaluate(self: *const HookSet, event: EventKind, name: []const u8, command: []const u8) !Evaluation {
        const gpa = self.gpa;

        const segs = try segments(gpa, command);
        defer {
            for (segs) |s| gpa.free(s);
            gpa.free(segs);
        }

        var matched: usize = 0;
        for (self.hooks.items) |h| {
            if (h.event == event and h.matcher.matches(name)) matched += 1;
        }

        for (segs) |seg| {
            for (self.deny_patterns.items) |p| {
                if (segmentDenied(p, seg)) {
                    return .{
                        .decision = .deny,
                        .matched_hooks = matched,
                        .segments_checked = segs.len,
                        .denied_segment = try gpa.dupe(u8, seg),
                    };
                }
            }
        }

        var decision: Decision = .pass;
        for (self.hooks.items) |h| {
            if (h.event != event) continue;
            if (!h.matcher.matches(name)) continue;
            decision = stricter(decision, decisionFromExitCode(h.code));
        }

        return .{
            .decision = decision,
            .matched_hooks = matched,
            .segments_checked = segs.len,
            .denied_segment = "",
        };
    }

    /// 把 hook 结论叠加到已有决策上：只可能更严。若 hook 比现有决策更松，
    /// 说明它试图越权，记录并忽略。
    pub fn applyTo(self: *HookSet, existing: Decision, hook_decision: Decision) Decision {
        const combined = stricter(existing, hook_decision);
        if (combined == existing and rank(hook_decision) < rank(existing)) {
            self.ignored_grants += 1;
        }
        return combined;
    }

    /// 硬门结论永远优先：hook 不能把门的 deny 翻成 pass。
    pub fn applyToGate(self: *HookSet, gate_decision: Decision, hook_decision: Decision) Decision {
        const combined = stricter(gate_decision, hook_decision);
        if (combined == gate_decision and rank(hook_decision) < rank(gate_decision)) {
            self.ignored_grants += 1;
        }
        return combined;
    }
};

test "matcher exact, prefix, alternation and wildcard" {
    const exact = Matcher{ .pattern = "graph_plan" };
    try std.testing.expect(exact.matches("graph_plan"));
    try std.testing.expect(!exact.matches("graph_run"));

    const prefix = Matcher{ .pattern = "design_*" };
    try std.testing.expect(prefix.matches("design_drc"));
    try std.testing.expect(!prefix.matches("graph_drc"));

    const alt = Matcher{ .pattern = "graph_run|design_drc" };
    try std.testing.expect(alt.matches("graph_run"));
    try std.testing.expect(alt.matches("design_drc"));
    try std.testing.expect(!alt.matches("loop_plan"));

    const all = Matcher{ .pattern = "*" };
    try std.testing.expect(all.matches("anything"));

    try std.testing.expectEqual(EventKind.pre_tool, eventFromString("pre_tool").?);
    try std.testing.expect(eventFromString("nope") == null);
}

test "exit code semantics: 0 pass, 2 deny, other warn" {
    try std.testing.expectEqual(Decision.pass, decisionFromExitCode(0));
    try std.testing.expectEqual(Decision.deny, decisionFromExitCode(2));
    try std.testing.expectEqual(Decision.warn, decisionFromExitCode(1));
    try std.testing.expectEqual(Decision.warn, decisionFromExitCode(127));
    try std.testing.expectEqual(Decision.deny, stricter(Decision.pass, Decision.deny));
    try std.testing.expectEqual(Decision.warn, stricter(Decision.warn, Decision.pass));
    try std.testing.expect(!hooks_can_override_gates);
}

test "compound commands are checked per segment" {
    const gpa = std.testing.allocator;
    const segs = try segments(gpa, "echo ok && rm -rf build || ls; cat a | grep b");
    defer {
        for (segs) |s| gpa.free(s);
        gpa.free(segs);
    }
    try std.testing.expectEqual(@as(usize, 5), segs.len);
    try std.testing.expectEqualStrings("echo ok", segs[0]);
    try std.testing.expectEqualStrings("rm -rf build", segs[1]);
    try std.testing.expectEqualStrings("ls", segs[2]);
    try std.testing.expectEqualStrings("cat a", segs[3]);
    try std.testing.expectEqualStrings("grep b", segs[4]);

    try std.testing.expect(segmentDenied("rm", "rm -rf build"));
    try std.testing.expect(!segmentDenied("rm", "confirm -rf build"));
}

test "deny pattern precedence beats a passing hook" {
    const gpa = std.testing.allocator;
    var set = HookSet.init(gpa);
    defer set.deinit();

    try set.add(EventKind.pre_tool, "bash", "echo allow");
    try set.denyPattern("rm");

    const ev = try set.evaluate(EventKind.pre_tool, "bash", "echo hi && rm -rf out");
    defer gpa.free(ev.denied_segment);
    try std.testing.expectEqual(Decision.deny, ev.decision);
    try std.testing.expectEqualStrings("rm -rf out", ev.denied_segment);
    try std.testing.expectEqual(@as(usize, 1), ev.matched_hooks);
    try std.testing.expectEqual(@as(usize, 2), ev.segments_checked);

    const clean = try set.evaluate(EventKind.pre_tool, "bash", "echo hi && ls");
    defer gpa.free(clean.denied_segment);
    try std.testing.expectEqual(Decision.pass, clean.decision);
}

test "hooks can only tighten a decision, never loosen it" {
    const gpa = std.testing.allocator;
    var set = HookSet.init(gpa);
    defer set.deinit();

    // 沙箱已经拒绝：hook 返回 0 不能把它翻成放行。
    try std.testing.expectEqual(Decision.deny, set.applyTo(Decision.deny, Decision.pass));
    try std.testing.expectEqual(@as(usize, 1), set.ignored_grants);

    // hook 返回 2：收紧。
    try std.testing.expectEqual(Decision.deny, set.applyTo(Decision.warn, Decision.deny));
    try std.testing.expectEqual(@as(usize, 1), set.ignored_grants);

    // 硬门优先：hook 不能把门的 deny 翻成 pass。
    try std.testing.expectEqual(Decision.deny, set.applyToGate(Decision.deny, Decision.pass));
    try std.testing.expectEqual(@as(usize, 2), set.ignored_grants);
}

test "matching hooks are scoped to their event" {
    const gpa = std.testing.allocator;
    var set = HookSet.init(gpa);
    defer set.deinit();

    try set.add(EventKind.pre_tool, "bash", "echo a");
    try set.add(EventKind.post_tool, "bash", "echo b");
    try set.add(EventKind.subagent_stop, "*", "echo c");

    const pre = try set.matching(EventKind.pre_tool, "bash");
    defer gpa.free(pre);
    try std.testing.expectEqual(@as(usize, 1), pre.len);

    const stop = try set.matching(EventKind.subagent_stop, "delegate");
    defer gpa.free(stop);
    try std.testing.expectEqual(@as(usize, 1), stop.len);
}
