//! 自进化门禁：提议 → 检查 → 合并 → 观测（观测在 claw/metrics 中闭环）。

const std = @import("std");
const memory = @import("memory.zig");

/// 流水线阶段标识。
pub const Stage = enum {
    propose,
    check,
    merge,
    observe,
};

/// 模型或宿主生成的技能更新提议（可自 JSON 反序列化）。
pub const Proposal = struct {
    skill_name: []const u8,
    version_hint: []const u8 = "",
    patch_summary: []const u8,
    new_body: []const u8,
    preconditions: []const u8 = "",
    prohibitions: []const u8 = "",
};

pub const CheckError = error{
    EmptyBody,
    NameTooShort,
    SummaryTooShort,
    BodyTooLarge,
};

pub const VersionError = error{
    EmptyVersion,
    InvalidSemver,
};

/// 合并策略。
pub const MergePolicy = enum {
    dry_run,
    auto_append_only,
    require_human,
};

pub fn policyTag(p: MergePolicy) []const u8 {
    return switch (p) {
        .dry_run => "dry_run",
        .auto_append_only => "auto_append_only",
        .require_human => "require_human",
    };
}

pub fn policyFromString(s: []const u8) ?MergePolicy {
    if (std.mem.eql(u8, s, "dry_run")) return .dry_run;
    if (std.mem.eql(u8, s, "auto_append_only")) return .auto_append_only;
    if (std.mem.eql(u8, s, "require_human")) return .require_human;
    return null;
}

pub const MergeDecision = union(enum) {
    accepted: memory.SkillVersion,
    rejected: []const u8,
    deferred: void,
};

const max_body_len: usize = 512 * 1024;

/// 静态规则门禁（可替换为沙箱测试、策略引擎等）。
pub fn checkProposal(p: Proposal) CheckError!void {
    if (p.new_body.len < 8) return error.EmptyBody;
    if (p.new_body.len > max_body_len) return error.BodyTooLarge;
    if (p.skill_name.len < 2) return error.NameTooShort;
    if (p.patch_summary.len < 4) return error.SummaryTooShort;
}

/// 宽松语义版本：`major.minor.patch` 或 `major.minor`，每段为数字。
pub fn isLooseSemver(v: []const u8) VersionError!void {
    if (v.len == 0) return error.EmptyVersion;
    if (v.len > 64) return error.InvalidSemver;
    var parts = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidSemver;
        for (part) |c| {
            if (c < '0' or c > '9') return error.InvalidSemver;
        }
        n += 1;
        if (n > 4) return error.InvalidSemver;
    }
    if (n < 1 or n > 3) return error.InvalidSemver;
}

pub fn materializeSkill(allo: std.mem.Allocator, p: Proposal, version: []const u8) !memory.SkillVersion {
    return .{
        .name = try allo.dupe(u8, p.skill_name),
        .version = try allo.dupe(u8, version),
        .preconditions = try allo.dupe(u8, p.preconditions),
        .prohibitions = try allo.dupe(u8, p.prohibitions),
        .body = try allo.dupe(u8, p.new_body),
    };
}

/// 根据策略产生合并决策；`auto_append_only` 会校验 `version` 为宽松 semver。
pub fn decideMerge(
    allo: std.mem.Allocator,
    p: Proposal,
    policy: MergePolicy,
    version: []const u8,
) !MergeDecision {
    checkProposal(p) catch |err| {
        return .{ .rejected = @errorName(err) };
    };
    switch (policy) {
        .dry_run => return .deferred,
        .require_human => return .deferred,
        .auto_append_only => {
            isLooseSemver(version) catch |err| {
                return .{ .rejected = @errorName(err) };
            };
            const skill = try materializeSkill(allo, p, version);
            return .{ .accepted = skill };
        },
    }
}

/// 流水线报告：便于宿主记录日志或二次持久化。
pub const PipelineReport = struct {
    stage_check_ok: bool,
    decision: MergeDecision,
};

test "check rejects short body" {
    const bad: Proposal = .{
        .skill_name = "ok",
        .version_hint = "1",
        .patch_summary = "abcd",
        .new_body = "short",
    };
    try std.testing.expectError(error.EmptyBody, checkProposal(bad));
}

test "semver" {
    try isLooseSemver("1.0.0");
    try isLooseSemver("0.2");
    try std.testing.expectError(error.InvalidSemver, isLooseSemver("v1.0"));
    try std.testing.expectError(error.EmptyVersion, isLooseSemver(""));
}

test "auto merge produces skill" {
    const gpa = std.testing.allocator;
    const p: Proposal = .{
        .skill_name = "login_flow",
        .version_hint = "x",
        .patch_summary = "handle 2fa",
        .new_body = "1. open page\n2. enter otp\n",
        .preconditions = "need browser",
        .prohibitions = "no store password",
    };
    const d = try decideMerge(gpa, p, .auto_append_only, "0.1.1");
    defer switch (d) {
        .accepted => |s| {
            gpa.free(s.name);
            gpa.free(s.version);
            gpa.free(s.preconditions);
            gpa.free(s.prohibitions);
            gpa.free(s.body);
        },
        else => {},
    };
    switch (d) {
        .accepted => |s| {
            try std.testing.expectEqualStrings("login_flow", s.name);
            try std.testing.expectEqualStrings("0.1.1", s.version);
            try std.testing.expectEqualStrings("need browser", s.preconditions);
        },
        else => try std.testing.expect(false),
    }
}
