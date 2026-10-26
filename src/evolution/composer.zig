//! 组合阶段：把通过探测的候选合并成 harness 配置补丁集。

const std = @import("std");
const evaluator = @import("evaluator.zig");
const proposer = @import("proposer.zig");

const Allocator = std.mem.Allocator;

pub const HarnessConfig = struct {
    gpa: Allocator,
    values: std.StringHashMap([]const u8),

    pub fn init(gpa: Allocator) HarnessConfig {
        return .{ .gpa = gpa, .values = std.StringHashMap([]const u8).init(gpa) };
    }

    pub fn deinit(self: *HarnessConfig) void {
        var it = self.values.iterator();
        while (it.next()) |e| {
            const alloc = self.gpa;
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.values.deinit();
    }

    pub fn set(self: *HarnessConfig, component: []const u8, body: []const u8) !void {
        const alloc = self.gpa;
        const entry = try self.values.getOrPut(component);
        if (!entry.found_existing) {
            entry.key_ptr.* = try alloc.dupe(u8, component);
            entry.value_ptr.* = try alloc.dupe(u8, body);
            return;
        }
        alloc.free(entry.value_ptr.*);
        entry.value_ptr.* = try alloc.dupe(u8, body);
    }

    pub fn get(self: *const HarnessConfig, component: []const u8) []const u8 {
        return self.values.get(component) orelse "";
    }
};

pub const Patch = struct {
    candidate_id: []const u8,
    component: []const u8,
    body: []const u8,
};

pub const Composition = struct {
    gpa: Allocator,
    patches: []Patch,
    skipped: []const []const u8,

    pub fn free(self: *const Composition) void {
        const alloc = self.gpa;
        for (self.patches) |p| {
            alloc.free(p.candidate_id);
            alloc.free(p.component);
            alloc.free(p.body);
        }
        alloc.free(self.patches);
        for (self.skipped) |s| alloc.free(s);
        alloc.free(self.skipped);
    }
};

/// 只合并未被淘汰且组件可编辑的候选；被跳过的原因记录在 `skipped`。
pub fn compose(gpa: Allocator, ranked: []const evaluator.RankedCandidate, candidates: []const proposer.Candidate, limit: usize) !Composition {
    var by_id = std.StringHashMap(proposer.Candidate).init(gpa);
    defer {
        var it = by_id.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        by_id.deinit();
    }
    for (candidates) |c| try by_id.put(try gpa.dupe(u8, c.id), c);

    var patches: std.ArrayList(Patch) = .empty;
    errdefer {
        for (patches.items) |p| {
            gpa.free(p.candidate_id);
            gpa.free(p.component);
            gpa.free(p.body);
        }
        patches.deinit(gpa);
    }

    var skipped: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (skipped.items) |s| gpa.free(s);
        skipped.deinit(gpa);
    }

    for (ranked) |r| {
        if (patches.items.len >= limit) break;
        const candidate = by_id.get(r.candidate_id) orelse continue;
        if (r.eliminated) {
            try skipped.append(gpa, try std.fmt.allocPrint(gpa, "{s}: eliminated by hard constraints", .{r.candidate_id}));
            continue;
        }
        if (!proposer.editable(candidate.component)) {
            try skipped.append(gpa, try std.fmt.allocPrint(gpa, "{s}: component {s} is not editable", .{ r.candidate_id, @tagName(candidate.component) }));
            continue;
        }
        try patches.append(gpa, .{
            .candidate_id = try gpa.dupe(u8, r.candidate_id),
            .component = try gpa.dupe(u8, @tagName(candidate.component)),
            .body = try gpa.dupe(u8, candidate.body),
        });
    }

    return .{
        .gpa = gpa,
        .patches = try patches.toOwnedSlice(gpa),
        .skipped = try skipped.toOwnedSlice(gpa),
    };
}

pub fn apply(gpa: Allocator, base: *const HarnessConfig, composition: *const Composition) !HarnessConfig {
    var out = HarnessConfig.init(gpa);
    errdefer out.deinit();

    var it = base.values.iterator();
    while (it.next()) |e| try out.set(e.key_ptr.*, e.value_ptr.*);
    for (composition.patches) |p| try out.set(p.component, p.body);
    return out;
}

test "compose skips eliminated and non-editable" {
    const gpa = std.testing.allocator;
    const candidates = [_]proposer.Candidate{
        .{ .id = "t1:skills", .component = .skills, .summary = "s", .body = "better body", .rationale = "r" },
        .{ .id = "t1:guardrails", .component = .guardrails, .summary = "s", .body = "nope", .rationale = "r" },
        .{ .id = "t2:memory", .component = .memory, .summary = "s", .body = "keep connector first", .rationale = "r" },
    };
    const ranked = [_]evaluator.RankedCandidate{
        .{ .candidate_id = "t1:skills", .eliminated = false, .metrics = .{ .engineering_pass_rate = 1.0, .design_quality = 1.2, .tool_reliability = 1.0, .iterations_to_pass = 2, .regression_rate = 0.0, .human_acceptance = 0.0, .samples = 1 } },
        .{ .candidate_id = "t1:guardrails", .eliminated = false, .metrics = .{ .engineering_pass_rate = 1.0, .design_quality = 1.1, .tool_reliability = 1.0, .iterations_to_pass = 1, .regression_rate = 0.0, .human_acceptance = 0.0, .samples = 1 } },
        .{ .candidate_id = "t2:memory", .eliminated = true, .metrics = .{ .engineering_pass_rate = 0.5, .design_quality = 1.0, .tool_reliability = 1.0, .iterations_to_pass = 1, .regression_rate = 0.0, .human_acceptance = 0.0, .samples = 1 } },
    };

    const composition = try compose(gpa, &ranked, &candidates, 10);
    defer composition.free();

    // guardrails 不可自动改写（设计原则），memory 因硬约束被淘汰：只有 skills 进入补丁集。
    try std.testing.expectEqual(@as(usize, 1), composition.patches.len);
    try std.testing.expectEqualStrings("skills", composition.patches[0].component);
    try std.testing.expectEqual(@as(usize, 2), composition.skipped.len);
    try std.testing.expect(std.mem.indexOf(u8, composition.skipped[0], "not editable") != null);
    try std.testing.expect(std.mem.indexOf(u8, composition.skipped[1], "eliminated") != null);

    var base = HarnessConfig.init(gpa);
    defer base.deinit();
    try base.set("skills", "old body");

    var applied = try apply(gpa, &base, &composition);
    defer applied.deinit();
    try std.testing.expectEqualStrings("better body", applied.get("skills"));
    // memory 被淘汰：不进入补丁集，保留基线值。
    try std.testing.expectEqualStrings("", applied.get("memory"));
}
