//! CuteClaw 运行时：Arena 托管记忆、`MetricsRegistry` 与显式工作区。

const std = @import("std");
const memory = @import("memory.zig");
const working = @import("working.zig");
const evolution = @import("evolution.zig");
const metrics = @import("metrics.zig");

const Allocator = std.mem.Allocator;

pub const ClawRuntime = struct {
    arena_state: std.heap.ArenaAllocator,
    episodic: std.ArrayList(memory.EpisodicRecord),
    skills: std.ArrayList(memory.SkillVersion),
    facts: std.ArrayList(memory.SemanticFact),
    metrics: metrics.MetricsRegistry,
    /// 工作区字段切片由 Arena 持有（经 `setWorking` 写入）。
    working: working.WorkingSet = .{},

    pub fn init(parent: Allocator) ClawRuntime {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(parent),
            .episodic = .empty,
            .skills = .empty,
            .facts = .empty,
            .metrics = metrics.MetricsRegistry.init(parent),
            .working = .{},
        };
    }

    pub fn deinit(self: *ClawRuntime) void {
        const al = self.allocator();
        self.episodic.deinit(al);
        self.skills.deinit(al);
        self.facts.deinit(al);
        self.arena_state.deinit();
        self.metrics.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *ClawRuntime) Allocator {
        return self.arena_state.allocator();
    }

    /// 清空情景/技能/事实、重置 Arena、清空指标与工作区（用于加载快照前）。
    pub fn resetContent(self: *ClawRuntime) void {
        const al = self.allocator();
        self.episodic.clearAndFree(al);
        self.skills.clearAndFree(al);
        self.facts.clearAndFree(al);
        _ = self.arena_state.reset(.retain_capacity);
        self.metrics.clear();
        self.working = .{};
    }

    pub fn rememberEpisode(self: *ClawRuntime, rec: memory.EpisodicRecord) !void {
        const al = self.allocator();
        const copy: memory.EpisodicRecord = .{
            .task_id = try al.dupe(u8, rec.task_id),
            .ended_unix = rec.ended_unix,
            .summary = try al.dupe(u8, rec.summary),
            .outcome = rec.outcome,
        };
        try self.episodic.append(al, copy);
    }

    pub fn addFact(self: *ClawRuntime, fact: memory.SemanticFact) !void {
        const al = self.allocator();
        const copy: memory.SemanticFact = .{
            .key = try al.dupe(u8, fact.key),
            .value = try al.dupe(u8, fact.value),
            .confidence = fact.confidence,
        };
        try self.facts.append(al, copy);
    }

    /// 追加一条技能（各字段复制到 Arena）。
    pub fn addSkillCopy(self: *ClawRuntime, s: memory.SkillVersion) !void {
        const al = self.allocator();
        try self.skills.append(al, .{
            .name = try al.dupe(u8, s.name),
            .version = try al.dupe(u8, s.version),
            .preconditions = try al.dupe(u8, s.preconditions),
            .prohibitions = try al.dupe(u8, s.prohibitions),
            .body = try al.dupe(u8, s.body),
        });
    }

    pub fn setWorking(self: *ClawRuntime, w: working.WorkingSet) !void {
        const al = self.allocator();
        self.working = .{
            .goal = try al.dupe(u8, w.goal),
            .constraints = try al.dupe(u8, w.constraints),
            .confirmed_facts = try al.dupe(u8, w.confirmed_facts),
            .next_step = try al.dupe(u8, w.next_step),
        };
    }

    /// 执行合并并写审计；`unix_ts` 建议为秒级 Unix 时间。
    pub fn applyProposal(
        self: *ClawRuntime,
        p: evolution.Proposal,
        policy: evolution.MergePolicy,
        version: []const u8,
        unix_ts: i64,
    ) !evolution.MergeDecision {
        const al = self.allocator();
        const decision = try evolution.decideMerge(al, p, policy, version);
        const result_tag: []const u8 = switch (decision) {
            .accepted => "accepted",
            .rejected => "rejected",
            .deferred => "deferred",
        };
        const detail: []const u8 = switch (decision) {
            .rejected => |r| r,
            .accepted => p.patch_summary,
            .deferred => "dry_run_or_human",
        };
        try self.metrics.recordEvolution(unix_ts, p.skill_name, evolution.policyTag(policy), result_tag, detail);
        switch (decision) {
            .accepted => |skill| try self.skills.append(al, skill),
            else => {},
        }
        return decision;
    }

    /// 记录任务闭合信号（累计成功/总数）。
    pub fn recordTaskSignal(self: *ClawRuntime, sig: metrics.TaskSignal) void {
        self.metrics.recordTask(sig);
    }

    /// 按技能名查找最新一条（同名多条时取最后一次 append）。
    pub fn findSkillLast(self: *const ClawRuntime, name: []const u8) ?memory.SkillVersion {
        var found: ?memory.SkillVersion = null;
        for (self.skills.items) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                found = s;
            }
        }
        return found;
    }
};

test "runtime roundtrip episode" {
    var claw_rt = ClawRuntime.init(std.testing.allocator);
    defer claw_rt.deinit();
    try claw_rt.rememberEpisode(.{
        .task_id = "t1",
        .ended_unix = 1700000000,
        .summary = "fixed login",
        .outcome = .success,
    });
    try std.testing.expectEqual(@as(usize, 1), claw_rt.episodic.items.len);
    try std.testing.expectEqualStrings("t1", claw_rt.episodic.items[0].task_id);
}

test "apply proposal writes audit" {
    var claw_rt = ClawRuntime.init(std.testing.allocator);
    defer claw_rt.deinit();
    const p: evolution.Proposal = .{
        .skill_name = "sk",
        .patch_summary = "summary here",
        .new_body = "12345678\nline",
    };
    _ = try claw_rt.applyProposal(p, .auto_append_only, "1.0.0", 99);
    try std.testing.expectEqual(@as(usize, 1), claw_rt.metrics.audit.items.len);
    try std.testing.expectEqual(@as(usize, 1), claw_rt.skills.items.len);
}
