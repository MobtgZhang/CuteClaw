//! 设计约束：硬约束先淘汰、软约束再排序（与 plan-1 的评估口径一致）。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Severity = enum { hard, soft };

pub const Kind = enum {
    trace_width,
    clearance,
    hole_diameter,
    board_area,
    rat_length,
    iterations,
    enclosure_wall,
    fit_clearance,
    courtyard_gap,
    board_margin,
    drc_errors,
};

pub const Direction = enum { min, max };

pub fn kindFromString(s: []const u8) ?Kind {
    if (std.meta.stringToEnum(Kind, s)) |k| return k;
    // 基准文件里的度量名可能带单位后缀（例如 rat_length_mm）：去掉后缀再解析。
    if (std.mem.lastIndexOfScalar(u8, s, '_')) |idx| {
        return std.meta.stringToEnum(Kind, s[0..idx]);
    }
    return null;
}

pub fn directionFromString(s: []const u8) ?Direction {
    if (std.mem.eql(u8, s, "min")) return .min;
    if (std.mem.eql(u8, s, "max")) return .max;
    return null;
}

pub fn severityFromString(s: []const u8) ?Severity {
    if (std.mem.eql(u8, s, "hard")) return .hard;
    if (std.mem.eql(u8, s, "soft")) return .soft;
    return null;
}

pub const Rule = struct {
    id: []const u8,
    kind: Kind,
    limit: f64,
    direction: Direction,
    severity: Severity,
};

pub const Measurement = struct {
    kind: Kind,
    value: f64,
    ref: []const u8,
};

pub fn satisfies(rule: Rule, value: f64) bool {
    return switch (rule.direction) {
        .min => value >= rule.limit,
        .max => value <= rule.limit,
    };
}

pub const ConstraintSet = struct {
    gpa: Allocator,
    rules: std.ArrayList(Rule),

    pub fn init(gpa: Allocator) ConstraintSet {
        return .{ .gpa = gpa, .rules = .empty };
    }

    pub fn deinit(self: *ConstraintSet) void {
        for (self.rules.items) |r| self.gpa.free(r.id);
        self.rules.deinit(self.gpa);
    }

    pub fn add(self: *ConstraintSet, rule: Rule) !void {
        try self.rules.append(self.gpa, .{
            .id = try self.gpa.dupe(u8, rule.id),
            .kind = rule.kind,
            .limit = rule.limit,
            .direction = rule.direction,
            .severity = rule.severity,
        });
    }

    pub fn count(self: *const ConstraintSet) usize {
        return self.rules.items.len;
    }

    pub fn find(self: *const ConstraintSet, id: []const u8) ?Rule {
        for (self.rules.items) |r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    pub fn findKind(self: *const ConstraintSet, kind: Kind) ?Rule {
        for (self.rules.items) |r| {
            if (r.kind == kind) return r;
        }
        return null;
    }

    pub fn check(self: *const ConstraintSet, measurements: []const Measurement) ![]Violation {
        var out: std.ArrayList(Violation) = .empty;
        errdefer out.deinit(
            self.gpa,
        );
        for (measurements) |m| {
            const rule = self.findKind(m.kind) orelse continue;
            if (satisfies(rule, m.value)) continue;
            try out.append(self.gpa, .{
                .rule_id = rule.id,
                .kind = m.kind,
                .ref = m.ref,
                .measured = m.value,
                .limit = rule.limit,
                .severity = rule.severity,
            });
        }
        return out.toOwnedSlice(
            self.gpa,
        );
    }

    pub fn satisfiesHard(self: *const ConstraintSet, measurements: []const Measurement) bool {
        for (measurements) |m| {
            const rule = self.findKind(m.kind) orelse continue;
            if (rule.severity == .hard and !satisfies(rule, m.value)) return false;
        }
        return true;
    }
};

pub const Violation = struct {
    rule_id: []const u8,
    kind: Kind,
    ref: []const u8,
    measured: f64,
    limit: f64,
    severity: Severity,
};

pub const Candidate = struct {
    id: []const u8,
    measurements: []const Measurement,
};

pub const Ranked = struct {
    id: []const u8,
    eliminated: bool,
    hard_violations: usize,
    soft_penalty: usize,
    /// 软约束（max 方向）的归一化代价，越小越好。
    optimization_cost: f64,
};

/// 先淘汰违反硬约束的候选，再按软惩罚与优化代价排序。
pub fn rank(gpa: Allocator, set: *const ConstraintSet, candidates: []const Candidate) ![]Ranked {
    var out: std.ArrayList(Ranked) = .empty;
    errdefer out.deinit(
        gpa,
    );

    for (candidates) |c| {
        var hard: usize = 0;
        var soft: usize = 0;
        var cost: f64 = 0.0;
        for (c.measurements) |m| {
            const rule = set.findKind(m.kind) orelse continue;
            if (!satisfies(rule, m.value)) {
                if (rule.severity == .hard) hard += 1 else soft += 1;
                continue;
            }
            // limit 为 0 时无法归一化：只按违规判定，不产生代价。
            if (rule.direction == .max and rule.limit != 0) cost += m.value / rule.limit;
        }
        try out.append(gpa, .{
            .id = c.id,
            .eliminated = hard > 0,
            .hard_violations = hard,
            .soft_penalty = soft,
            .optimization_cost = cost,
        });
    }

    std.sort.insertion(Ranked, out.items, {}, rankedLessThan);
    return out.toOwnedSlice(
        gpa,
    );
}

fn rankedLessThan(_: void, a: Ranked, b: Ranked) bool {
    if (a.eliminated != b.eliminated) return !a.eliminated;
    if (a.soft_penalty != b.soft_penalty) return a.soft_penalty < b.soft_penalty;
    return a.optimization_cost < b.optimization_cost;
}

test "hard elimination before ranking" {
    const gpa = std.testing.allocator;
    var set = ConstraintSet.init(gpa);
    defer set.deinit();

    try set.add(.{ .id = "min_trace_width", .kind = .trace_width, .limit = 0.2, .direction = .min, .severity = .hard });
    try set.add(.{ .id = "rat_length", .kind = .rat_length, .limit = 900, .direction = .max, .severity = .soft });

    const a = [_]Measurement{
        .{ .kind = .trace_width, .value = 0.3, .ref = "A" },
        .{ .kind = .rat_length, .value = 820, .ref = "A" },
    };
    const b = [_]Measurement{
        .{ .kind = .trace_width, .value = 0.25, .ref = "B" },
        .{ .kind = .rat_length, .value = 670, .ref = "B" },
    };
    const c = [_]Measurement{
        .{ .kind = .trace_width, .value = 0.12, .ref = "C" },
        .{ .kind = .rat_length, .value = 590, .ref = "C" },
    };
    const candidates = [_]Candidate{
        .{ .id = "A", .measurements = &a },
        .{ .id = "B", .measurements = &b },
        .{ .id = "C", .measurements = &c },
    };

    const ranked = try rank(gpa, &set, &candidates);
    defer gpa.free(ranked);

    try std.testing.expectEqualStrings("B", ranked[0].id);
    try std.testing.expectEqualStrings("A", ranked[1].id);
    try std.testing.expectEqualStrings("C", ranked[2].id);
    try std.testing.expect(ranked[2].eliminated);
    try std.testing.expect(set.satisfiesHard(&b));
    try std.testing.expect(!set.satisfiesHard(&c));
}

test "rule lookup and severity parse" {
    const gpa = std.testing.allocator;
    var set = ConstraintSet.init(gpa);
    defer set.deinit();
    try set.add(.{ .id = "min_clearance", .kind = .clearance, .limit = 0.2, .direction = .min, .severity = .hard });
    const rule = set.find("min_clearance") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Severity.hard, rule.severity);
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expectEqual(@as(?Direction, .min), directionFromString("min"));
    try std.testing.expectEqual(@as(?Severity, .soft), severityFromString("soft"));
    try std.testing.expectEqual(@as(?Severity, null), severityFromString("maybe"));
}
