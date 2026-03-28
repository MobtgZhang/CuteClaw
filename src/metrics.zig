//! 任务与技能级信号、审计日志与滚动统计（可持久化）。

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const RetryStats = struct {
    tool_errors: u32 = 0,
    llm_retries: u32 = 0,
};

pub const TaskSignal = struct {
    task_id: []const u8,
    success: bool,
    turn_count: u32,
    retries: RetryStats,
};

pub const SkillRollup = struct {
    skill_name: []const u8,
    invocations: u32 = 0,
    successes: u32 = 0,
    failures: u32 = 0,
    last_patch_unix: i64 = 0,
};

pub const AuditEntry = struct {
    unix_ts: i64,
    skill_name: []const u8,
    policy: []const u8,
    result: []const u8,
    detail: []const u8,
};

pub fn successRate(rollup: SkillRollup) f32 {
    if (rollup.invocations == 0) return 0;
    return @as(f32, @floatFromInt(rollup.successes)) / @as(f32, @floatFromInt(rollup.invocations));
}

const RollupInternal = struct {
    invocations: u32,
    successes: u32,
    failures: u32,
    last_patch_unix: i64,
};

pub const MetricsRegistry = struct {
    gpa: Allocator,
    rollups: std.StringArrayHashMap(RollupInternal),
    audit: std.ArrayList(AuditEntry),
    audit_cap: usize,
    tasks_recorded: u64,
    tasks_succeeded: u64,

    pub fn init(gpa: Allocator) MetricsRegistry {
        return .{
            .gpa = gpa,
            .rollups = std.StringArrayHashMap(RollupInternal).init(gpa),
            .audit = .empty,
            .audit_cap = 512,
            .tasks_recorded = 0,
            .tasks_succeeded = 0,
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        var it = self.rollups.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
        }
        self.rollups.deinit();
        for (self.audit.items) |a| {
            self.gpa.free(a.skill_name);
            self.gpa.free(a.policy);
            self.gpa.free(a.result);
            self.gpa.free(a.detail);
        }
        self.audit.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn clear(self: *MetricsRegistry) void {
        var it = self.rollups.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
        }
        self.rollups.clearRetainingCapacity();
        for (self.audit.items) |a| {
            self.gpa.free(a.skill_name);
            self.gpa.free(a.policy);
            self.gpa.free(a.result);
            self.gpa.free(a.detail);
        }
        self.audit.clearRetainingCapacity();
        self.tasks_recorded = 0;
        self.tasks_succeeded = 0;
    }

    pub fn rollupCount(self: *const MetricsRegistry) usize {
        return self.rollups.count();
    }

    pub fn recordTask(self: *MetricsRegistry, sig: TaskSignal) void {
        self.tasks_recorded += 1;
        if (sig.success) self.tasks_succeeded += 1;
    }

    pub fn recordSkillInvocation(self: *MetricsRegistry, skill_name: []const u8, success: bool, unix_ts: i64) !void {
        if (self.rollups.getPtr(skill_name)) |ptr| {
            ptr.invocations += 1;
            if (success) {
                ptr.successes += 1;
            } else {
                ptr.failures += 1;
            }
            ptr.last_patch_unix = unix_ts;
            return;
        }
        const owned = try self.gpa.dupe(u8, skill_name);
        errdefer self.gpa.free(owned);
        try self.rollups.put(owned, .{
            .invocations = 1,
            .successes = if (success) @as(u32, 1) else 0,
            .failures = if (success) @as(u32, 0) else 1,
            .last_patch_unix = unix_ts,
        });
    }

    pub fn recordEvolution(
        self: *MetricsRegistry,
        unix_ts: i64,
        skill_name: []const u8,
        policy_tag: []const u8,
        result_tag: []const u8,
        detail: []const u8,
    ) !void {
        const entry: AuditEntry = .{
            .unix_ts = unix_ts,
            .skill_name = try self.gpa.dupe(u8, skill_name),
            .policy = try self.gpa.dupe(u8, policy_tag),
            .result = try self.gpa.dupe(u8, result_tag),
            .detail = try self.gpa.dupe(u8, detail),
        };
        try self.audit.append(self.gpa, entry);
        if (self.audit.items.len > self.audit_cap) {
            const old = self.audit.orderedRemove(0);
            self.gpa.free(old.skill_name);
            self.gpa.free(old.policy);
            self.gpa.free(old.result);
            self.gpa.free(old.detail);
        }

        if (std.mem.eql(u8, result_tag, "accepted")) {
            if (self.rollups.getPtr(skill_name)) |ptr| {
                ptr.last_patch_unix = unix_ts;
            } else {
                const owned = try self.gpa.dupe(u8, skill_name);
                errdefer self.gpa.free(owned);
                try self.rollups.put(owned, .{
                    .invocations = 0,
                    .successes = 0,
                    .failures = 0,
                    .last_patch_unix = unix_ts,
                });
            }
        }
    }

    pub fn rollupSnapshot(self: *const MetricsRegistry, gpa: Allocator, out: *std.ArrayList(SkillRollup)) !void {
        out.clearRetainingCapacity();
        var it = self.rollups.iterator();
        while (it.next()) |e| {
            try out.append(gpa, .{
                .skill_name = e.key_ptr.*,
                .invocations = e.value_ptr.invocations,
                .successes = e.value_ptr.successes,
                .failures = e.value_ptr.failures,
                .last_patch_unix = e.value_ptr.last_patch_unix,
            });
        }
    }

    pub fn seedRollup(self: *MetricsRegistry, r: SkillRollup) !void {
        if (self.rollups.fetchSwapRemove(r.skill_name)) |kv| {
            self.gpa.free(kv.key);
        }
        const owned = try self.gpa.dupe(u8, r.skill_name);
        errdefer self.gpa.free(owned);
        try self.rollups.put(owned, .{
            .invocations = r.invocations,
            .successes = r.successes,
            .failures = r.failures,
            .last_patch_unix = r.last_patch_unix,
        });
    }
};

test "success rate" {
    const r: SkillRollup = .{ .skill_name = "demo", .invocations = 4, .successes = 3 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), successRate(r), 0.001);
}

test "registry audit cap" {
    var r = MetricsRegistry.init(std.testing.allocator);
    defer r.deinit();
    r.audit_cap = 3;
    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        try r.recordEvolution(i, "s", "p", "accepted", "d");
    }
    try std.testing.expectEqual(@as(usize, 3), r.audit.items.len);
}
