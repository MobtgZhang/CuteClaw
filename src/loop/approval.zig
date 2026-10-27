//! 审批层：模式（never / on_request / untrusted）+ 规则（allow / deny / ask）+ 会话级"总是允许"。
//!
//! 三条不可协商的规则：
//! - deny 规则永远优先于 allow 规则与会话级授权；
//! - 不可逆动作在任何模式下都必须人工确认，会话级授权覆盖不到它；
//! - 会话级授权只在当前会话内有效，resetSession 即失效。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mode = enum { never, on_request, untrusted };

pub fn modeFromString(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "never")) return .never;
    if (std.mem.eql(u8, s, "on_request")) return .on_request;
    if (std.mem.eql(u8, s, "untrusted")) return .untrusted;
    return null;
}

pub const Decision = enum { allow, ask, deny };

pub const Rule = struct {
    /// 工具名，或 `*` 表示所有工具。
    tool: []const u8,
    /// 命令前缀规则：`git pull` 匹配 `git pull --rebase`，但不匹配 `git pullfoo`。
    pattern: []const u8,
    decision: Decision,
};

pub const Grant = struct { tool: []const u8, pattern: []const u8 };

/// 不可逆动作：删掉的东西、推上去的东西、覆盖掉的远端状态， rewind 也救不回来。
pub const irreversible_markers = [_][]const u8{
    "--force",
    "-f",
    "reset --hard",
    "clean -fdx",
    "rm -rf",
    "drop",
    "truncate",
    "deploy --prod",
    "overwrite",
};

pub fn isIrreversible(command: []const u8) bool {
    for (irreversible_markers) |m| {
        if (std.mem.indexOf(u8, command, m) != null) return true;
    }
    return false;
}

pub fn toolMatches(rule_tool: []const u8, tool: []const u8) bool {
    if (std.mem.eql(u8, rule_tool, "*")) return true;
    return std.mem.eql(u8, rule_tool, tool);
}

pub fn patternMatches(pattern: []const u8, command: []const u8) bool {
    if (pattern.len == 0 or std.mem.eql(u8, pattern, "*")) return true;
    const cmd = std.mem.trim(u8, command, " \t");
    if (!std.mem.startsWith(u8, cmd, pattern)) return false;
    if (cmd.len == pattern.len) return true;
    // 前缀必须落在 token 边界上，避免 `git pull` 命中 `git pullfoo`。
    const rest = cmd[pattern.len];
    return rest == ' ' or rest == '\t';
}

pub const Approval = struct {
    gpa: Allocator,
    mode: Mode,
    rules: std.ArrayList(Rule),
    session_grants: std.ArrayList(Grant),
    /// 被会话级授权覆盖但因此被拒绝的次数（不可逆动作）。
    refused_grants: usize = 0,

    pub fn init(gpa: Allocator, mode: Mode) Approval {
        return .{
            .gpa = gpa,
            .mode = mode,
            .rules = .empty,
            .session_grants = .empty,
        };
    }

    pub fn deinit(self: *Approval) void {
        for (self.rules.items) |r| {
            self.gpa.free(r.tool);
            self.gpa.free(r.pattern);
        }
        self.rules.deinit(self.gpa);
        for (self.session_grants.items) |g| {
            self.gpa.free(g.tool);
            self.gpa.free(g.pattern);
        }
        self.session_grants.deinit(self.gpa);
    }

    pub fn addRule(self: *Approval, tool: []const u8, pattern: []const u8, decision: Decision) !void {
        try self.rules.append(self.gpa, .{
            .tool = try self.gpa.dupe(u8, tool),
            .pattern = try self.gpa.dupe(u8, pattern),
            .decision = decision,
        });
    }

    /// 会话级"总是允许"：只在本会话内有效。
    pub fn grantSession(self: *Approval, tool: []const u8, pattern: []const u8) !void {
        try self.session_grants.append(self.gpa, .{
            .tool = try self.gpa.dupe(u8, tool),
            .pattern = try self.gpa.dupe(u8, pattern),
        });
    }

    pub fn resetSession(self: *Approval) void {
        for (self.session_grants.items) |g| {
            self.gpa.free(g.tool);
            self.gpa.free(g.pattern);
        }
        self.session_grants.clearRetainingCapacity();
    }

    pub fn decide(self: *Approval, tool: []const u8, command: []const u8) Decision {
        // 1) deny 规则优先。
        for (self.rules.items) |r| {
            if (r.decision == .deny and toolMatches(r.tool, tool) and patternMatches(r.pattern, command)) return .deny;
        }

        // 2) 不可逆动作永远需要人工确认，哪怕已经"总是允许"。
        if (isIrreversible(command)) {
            for (self.session_grants.items) |g| {
                if (toolMatches(g.tool, tool) and patternMatches(g.pattern, command)) self.refused_grants += 1;
            }
            return .ask;
        }

        // 3) 会话级授权。
        for (self.session_grants.items) |g| {
            if (toolMatches(g.tool, tool) and patternMatches(g.pattern, command)) return .allow;
        }

        // 4) allow 规则。
        for (self.rules.items) |r| {
            if (r.decision == .allow and toolMatches(r.tool, tool) and patternMatches(r.pattern, command)) return .allow;
        }

        // 5) 模式默认值。
        return switch (self.mode) {
            .never => .allow,
            .on_request, .untrusted => .ask,
        };
    }
};

test "prefix rules match at token boundaries" {
    try std.testing.expect(patternMatches("git pull", "git pull --rebase"));
    try std.testing.expect(patternMatches("git pull", "git pull"));
    try std.testing.expect(!patternMatches("git pull", "git pullfoo"));
    try std.testing.expect(patternMatches("*", "anything"));
    try std.testing.expect(toolMatches("*", "bash"));
    try std.testing.expect(!toolMatches("bash", "graph_plan"));
}

test "irreversible actions always need a human" {
    try std.testing.expect(isIrreversible("git push --force origin main"));
    try std.testing.expect(isIrreversible("rm -rf build"));
    try std.testing.expect(!isIrreversible("git status"));
}

test "deny precedence beats allow rules and session grants" {
    const gpa = std.testing.allocator;
    var a = Approval.init(gpa, .untrusted);
    defer a.deinit();

    try a.addRule("*", "*", Decision.ask);
    try a.addRule("bash", "git", Decision.allow);
    try a.addRule("bash", "git push", Decision.deny);
    try a.grantSession("bash", "git push --force");

    try std.testing.expectEqual(Decision.deny, a.decide("bash", "git push --force origin main"));
    // deny 在不可逆检查之前返回：这条会话级授权根本没有机会被"覆盖"。
    try std.testing.expectEqual(@as(usize, 0), a.refused_grants);
    try std.testing.expectEqual(Decision.allow, a.decide("bash", "git pull --rebase"));
}

test "session grants are session scoped and cannot cover irreversible actions" {
    const gpa = std.testing.allocator;
    var a = Approval.init(gpa, .on_request);
    defer a.deinit();

    try a.grantSession("bash", "npm test");
    try std.testing.expectEqual(Decision.allow, a.decide("bash", "npm test --watch"));
    try std.testing.expectEqual(Decision.ask, a.decide("bash", "npm install"));

    a.resetSession();
    try std.testing.expectEqual(Decision.ask, a.decide("bash", "npm test"));

    // 即便有覆盖一切的会话级授权，不可逆动作仍然必须人工确认。
    try a.grantSession("*", "*");
    try std.testing.expectEqual(Decision.ask, a.decide("bash", "rm -rf out"));
    try std.testing.expectEqual(@as(usize, 1), a.refused_grants);
}

test "mode defaults" {
    const gpa = std.testing.allocator;

    var never = Approval.init(gpa, .never);
    defer never.deinit();
    try std.testing.expectEqual(Decision.allow, never.decide("bash", "ls"));
    try std.testing.expectEqual(Decision.ask, never.decide("bash", "rm -rf out"));

    var on_request = Approval.init(gpa, .on_request);
    defer on_request.deinit();
    try std.testing.expectEqual(Decision.ask, on_request.decide("bash", "ls"));

    var untrusted = Approval.init(gpa, .untrusted);
    defer untrusted.deinit();
    try std.testing.expectEqual(Decision.ask, untrusted.decide("bash", "ls"));
    try untrusted.addRule("bash", "ls", Decision.allow);
    try std.testing.expectEqual(Decision.allow, untrusted.decide("bash", "ls -la"));

    try std.testing.expectEqual(Mode.on_request, modeFromString("on_request").?);
    try std.testing.expect(modeFromString("nope") == null);
}
