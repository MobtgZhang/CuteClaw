//! 升级阶段：指标门禁 + 版本历史 + 回滚（复用既有 evolution 合并策略与审计）。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const memory = @import("../memory.zig");
const evolution = @import("../evolution.zig");
const evaluator = @import("evaluator.zig");
const proposer = @import("proposer.zig");

const Allocator = std.mem.Allocator;

pub const Gate = struct {
    min_pass_rate: f64 = 1.0,
    min_quality_gain: f64 = 1.05,
    max_regression_rate: f64 = 0.05,
    min_tool_reliability: f64 = 0.9,
    policy: evolution.MergePolicy = .require_human,
};

// 门禁结论直接复用进化内核的判定类型，避免两套结构在调用处无法互转。
pub const Decision = evolution.MergeDecision;

pub fn gateCheck(gpa: Allocator, candidate: proposer.Candidate, metrics: evaluator.Metrics, version: []const u8, gate: Gate) !Decision {
    if (metrics.samples == 0) return .{ .rejected = "no_samples" };
    if (metrics.engineering_pass_rate < gate.min_pass_rate) return .{ .rejected = "pass_rate_below_gate" };
    if (metrics.design_quality < gate.min_quality_gain) return .{ .rejected = "quality_below_gate" };
    if (metrics.regression_rate > gate.max_regression_rate) return .{ .rejected = "regression_above_gate" };
    if (metrics.tool_reliability < gate.min_tool_reliability) return .{ .rejected = "tool_reliability_below_gate" };

    const proposal = evolution.Proposal{
        .skill_name = @tagName(candidate.component),
        .version_hint = version,
        .patch_summary = candidate.summary,
        .new_body = candidate.body,
        .preconditions = "fixed unseen benchmark set",
        .prohibitions = "no auto edit of hard design rules",
    };
    return evolution.decideMerge(gpa, proposal, gate.policy, version);
}

pub const Entry = struct {
    version: []const u8,
    candidate_id: []const u8,
    unix_ts: i64,
    promoted: bool,
};

/// 版本账本：记录每次升级，支持回滚到历史版本。
pub const Ledger = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry),
    active: usize,

    pub fn init(gpa: Allocator) Ledger {
        return .{ .gpa = gpa, .entries = .empty, .active = 0 };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.version);
            self.gpa.free(e.candidate_id);
        }
        self.entries.deinit(self.gpa);
    }

    pub fn record(self: *Ledger, candidate_id: []const u8, version: []const u8, promoted: bool, unix_ts: i64) !void {
        try self.entries.append(self.gpa, .{
            .version = try self.gpa.dupe(u8, version),
            .candidate_id = try self.gpa.dupe(u8, candidate_id),
            .unix_ts = unix_ts,
            .promoted = promoted,
        });
        if (promoted) self.active = self.entries.items.len - 1;
    }

    pub fn activeVersion(self: *const Ledger) []const u8 {
        if (self.entries.items.len == 0) return "";
        return self.entries.items[self.active].version;
    }

    pub fn rollback(self: *Ledger, version: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.version, version)) {
                self.active = i;
                return true;
            }
        }
        return false;
    }

    pub fn toJson(self: *const Ledger) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "active", try ju.strVal(self.gpa, self.activeVersion()));
        var arr = ju.newArr(self.gpa);
        for (self.entries.items) |e| {
            var item = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &item.object, "version", try ju.strVal(self.gpa, e.version));
            try ju.putKey(self.gpa, &item.object, "candidate", try ju.strVal(self.gpa, e.candidate_id));
            try ju.putKey(self.gpa, &item.object, "promoted", .{ .bool = e.promoted });
            try arr.array.append(item);
        }
        try ju.putKey(self.gpa, &obj.object, "entries", arr);
        return obj;
    }
};

test "promotion gate and rollback" {
    const gpa = std.testing.allocator;
    const candidate = proposer.Candidate{
        .id = "t1:skills",
        .component = .skills,
        .summary = "cluster connectors first",
        .body = "1. place connectors\n2. cluster nets\n",
        .rationale = "evidence",
    };

    const good = evaluator.Metrics{
        .engineering_pass_rate = 1.0,
        .design_quality = 1.2,
        .tool_reliability = 0.95,
        .iterations_to_pass = 2.0,
        .regression_rate = 0.0,
        .human_acceptance = 0.5,
        .samples = 4,
    };

    const gate = Gate{ .policy = .auto_append_only };
    const decision = try gateCheck(gpa, candidate, good, "0.2.0", gate);
    switch (decision) {
        .accepted => |skill| {
            gpa.free(skill.name);
            gpa.free(skill.version);
            gpa.free(skill.preconditions);
            gpa.free(skill.prohibitions);
            gpa.free(skill.body);
        },
        else => return error.TestUnexpectedResult,
    }

    const bad = evaluator.Metrics{
        .engineering_pass_rate = 0.5,
        .design_quality = 1.2,
        .tool_reliability = 0.95,
        .iterations_to_pass = 2.0,
        .regression_rate = 0.0,
        .human_acceptance = 0.0,
        .samples = 2,
    };
    const rejected = try gateCheck(gpa, candidate, bad, "0.2.0", gate);
    switch (rejected) {
        .rejected => |reason| try std.testing.expectEqualStrings("pass_rate_below_gate", reason),
        else => return error.TestUnexpectedResult,
    }

    const human_gate = Gate{ .policy = .require_human };
    const deferred = try gateCheck(gpa, candidate, good, "0.2.0", human_gate);
    try std.testing.expect(deferred == .deferred);

    var ledger = Ledger.init(gpa);
    defer ledger.deinit();
    try ledger.record("t1:skills", "0.2.0", true, 1700000000);
    try ledger.record("t2:memory", "0.2.1", true, 1700000100);
    try std.testing.expectEqualStrings("0.2.1", ledger.activeVersion());
    try std.testing.expect(ledger.rollback("0.2.0"));
    try std.testing.expectEqualStrings("0.2.0", ledger.activeVersion());
    try std.testing.expect(!ledger.rollback("9.9.9"));

    const json = try ledger.toJson();
    defer ju.freeJsonValue(gpa, json);
    const text = try ju.stringifyAlloc(gpa, json);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"active\":\"0.2.0\"") != null);
}
