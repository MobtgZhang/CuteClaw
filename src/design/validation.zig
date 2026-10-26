//! DRC：线宽、间距、板框余量、courtyard 重叠与孔径。硬约束优先于排序。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const geometry = @import("geometry.zig");
const pcb = @import("pcb.zig");
const constraints = @import("constraints.zig");

const Allocator = std.mem.Allocator;

pub fn severityTag(s: constraints.Severity) []const u8 {
    return switch (s) {
        .hard => "hard",
        .soft => "soft",
    };
}

pub const Issue = struct {
    rule_id: []const u8,
    severity: constraints.Severity,
    ref: []const u8,
    measured: f64,
    limit: f64,
    message: []const u8,
};

pub const Report = struct {
    gpa: Allocator,
    issues: []Issue,
    hard_count: usize,
    soft_count: usize,

    pub fn passed(self: *const Report) bool {
        return self.hard_count == 0;
    }

    pub fn free(self: *const Report) void {
        for (self.issues) |i| {
            self.gpa.free(i.rule_id);
            self.gpa.free(i.ref);
            self.gpa.free(i.message);
        }
        self.gpa.free(self.issues);
    }

    pub fn toJson(self: *const Report) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "passed", .{ .bool = self.passed() });
        try ju.putKey(self.gpa, &obj.object, "hard_count", .{ .integer = @intCast(self.hard_count) });
        try ju.putKey(self.gpa, &obj.object, "soft_count", .{ .integer = @intCast(self.soft_count) });
        var arr = ju.newArr(self.gpa);
        for (self.issues) |i| {
            var item = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &item.object, "rule", try ju.strVal(self.gpa, i.rule_id));
            try ju.putKey(self.gpa, &item.object, "severity", try ju.strVal(self.gpa, severityTag(i.severity)));
            try ju.putKey(self.gpa, &item.object, "ref", try ju.strVal(self.gpa, i.ref));
            try ju.putKey(self.gpa, &item.object, "measured", .{ .float = i.measured });
            try ju.putKey(self.gpa, &item.object, "limit", .{ .float = i.limit });
            try ju.putKey(self.gpa, &item.object, "message", try ju.strVal(self.gpa, i.message));
            try arr.array.append(item);
        }
        try ju.putKey(self.gpa, &obj.object, "issues", arr);
        return obj;
    }
};

/// 收集一次 DRC 的测量值：每个被检查对象一条，ref 标注来源。
pub fn measurements(gpa: Allocator, board: *const pcb.Board) ![]constraints.Measurement {
    var out: std.ArrayList(constraints.Measurement) = .empty;
    errdefer out.deinit(gpa);

    try out.append(gpa, .{
        .kind = .trace_width,
        .value = board.trace_width,
        .ref = try gpa.dupe(u8, "board"),
    });

    const groups = try board.netGroups();
    defer pcb.Board.freeNets(gpa, groups);

    // 不同网络焊盘之间的最小间距
    for (board.pads.items) |a| {
        for (board.pads.items) |b| {
            if (std.mem.eql(u8, a.net, b.net)) continue;
            try out.append(gpa, .{
                .kind = .clearance,
                .value = a.pos.distanceTo(b.pos),
                .ref = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ a.component, b.component }),
            });
        }
    }

    // courtyard 重叠（间隙为 0 即视为违规）
    for (board.components.items) |a| {
        for (board.components.items) |b| {
            if (std.mem.eql(u8, a.ref, b.ref)) continue;
            try out.append(gpa, .{
                .kind = .courtyard_gap,
                .value = a.courtyard().gap(b.courtyard()),
                .ref = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ a.ref, b.ref }),
            });
        }
    }

    // 板框余量
    for (board.components.items) |c| {
        const r = c.courtyard();
        const margin = @min(@min(r.min.x - board.bounds.min.x, board.bounds.max.x - r.max.x), @min(r.min.y - board.bounds.min.y, board.bounds.max.y - r.max.y));
        try out.append(gpa, .{
            .kind = .board_margin,
            .value = margin,
            .ref = try gpa.dupe(u8, c.ref),
        });
    }

    for (board.holes.items) |h| {
        try out.append(gpa, .{ .kind = .hole_diameter, .value = h.diameter, .ref = try gpa.dupe(u8, h.ref) });
    }

    return out.toOwnedSlice(gpa);
}

pub fn runDrc(gpa: Allocator, board: *const pcb.Board, set: *const constraints.ConstraintSet) !Report {
    const measured = try measurements(gpa, board);
    defer {
        for (measured) |m| gpa.free(m.ref);
        gpa.free(measured);
    }

    const violations = try set.check(measured);
    defer gpa.free(violations);

    var issues: std.ArrayList(Issue) = .empty;
    errdefer {
        for (issues.items) |i| {
            gpa.free(i.rule_id);
            gpa.free(i.ref);
            gpa.free(i.message);
        }
        issues.deinit(gpa);
    }

    var hard: usize = 0;
    var soft: usize = 0;
    for (violations) |v| {
        const message = try std.fmt.allocPrint(gpa, "{s} {s} ref={s} measured={d} limit={d}", .{
            v.rule_id,
            severityTag(v.severity),
            v.ref,
            v.measured,
            v.limit,
        });
        errdefer gpa.free(message);
        try issues.append(gpa, .{
            .rule_id = try gpa.dupe(u8, v.rule_id),
            .severity = v.severity,
            .ref = try gpa.dupe(u8, v.ref),
            .measured = v.measured,
            .limit = v.limit,
            .message = message,
        });
        if (v.severity == .hard) hard += 1 else soft += 1;
    }

    return .{
        .gpa = gpa,
        .issues = try issues.toOwnedSlice(gpa),
        .hard_count = hard,
        .soft_count = soft,
    };
}

test "drc reports clearance and overlap violations" {
    const gpa = std.testing.allocator;
    var set = constraints.ConstraintSet.init(gpa);
    defer set.deinit();
    try set.add(.{ .id = "min_trace_width", .kind = .trace_width, .limit = 0.2, .direction = .min, .severity = .hard });
    try set.add(.{ .id = "min_clearance", .kind = .clearance, .limit = 0.3, .direction = .min, .severity = .hard });
    try set.add(.{ .id = "min_courtyard_gap", .kind = .courtyard_gap, .limit = 0.0, .direction = .min, .severity = .hard });
    try set.add(.{ .id = "min_board_margin", .kind = .board_margin, .limit = 1.0, .direction = .min, .severity = .soft });

    var board = try pcb.Board.init(gpa, "drc-demo");
    defer board.deinit();
    board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };

    try board.addComponent(.{ .ref = "U1", .footprint = "QFP", .center = .{ .x = 5, .y = 5 }, .rotation_deg = 0, .width = 7, .height = 7, .courtyard_margin = 0.25 });
    try board.addComponent(.{ .ref = "C1", .footprint = "0603", .center = .{ .x = 8, .y = 5 }, .rotation_deg = 0, .width = 2, .height = 1, .courtyard_margin = 0.25 });
    try board.addComponent(.{ .ref = "C2", .footprint = "M2", .center = .{ .x = 0.5, .y = 10 }, .rotation_deg = 0, .width = 1, .height = 1, .courtyard_margin = 0.25 });
    try board.addPad(.{ .component = "U1", .net = "GND", .pos = .{ .x = 5, .y = 5 } });
    try board.addPad(.{ .component = "C1", .net = "VBUS", .pos = .{ .x = 5.1, .y = 5.2 } });

    var report = try runDrc(gpa, &board, &set);
    defer report.free();

    try std.testing.expect(!report.passed());
    try std.testing.expect(report.hard_count >= 2);
    try std.testing.expect(report.soft_count >= 1);

    const json = try report.toJson();
    defer ju.freeJsonValue(gpa, json);
    const text = try ju.stringifyAlloc(gpa, json);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "min_clearance") != null);
}

test "clean board passes drc" {
    const gpa = std.testing.allocator;
    var set = constraints.ConstraintSet.init(gpa);
    defer set.deinit();
    try set.add(.{ .id = "min_trace_width", .kind = .trace_width, .limit = 0.2, .direction = .min, .severity = .hard });
    try set.add(.{ .id = "min_clearance", .kind = .clearance, .limit = 0.3, .direction = .min, .severity = .hard });

    var board = try pcb.Board.init(gpa, "clean");
    defer board.deinit();
    board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 60, .y = 40 } };
    try board.addComponent(.{ .ref = "U1", .footprint = "QFP", .center = .{ .x = 10, .y = 10 }, .rotation_deg = 0, .width = 7, .height = 7, .courtyard_margin = 0.25 });
    try board.addComponent(.{ .ref = "C1", .footprint = "0603", .center = .{ .x = 30, .y = 20 }, .rotation_deg = 0, .width = 2, .height = 1, .courtyard_margin = 0.25 });
    try board.addPad(.{ .component = "U1", .net = "GND", .pos = .{ .x = 10, .y = 10 } });
    try board.addPad(.{ .component = "C1", .net = "VBUS", .pos = .{ .x = 30, .y = 20 } });
    try board.addHole(.{ .ref = "H1", .pos = .{ .x = 3, .y = 3 }, .diameter = 3.2 });

    var report = try runDrc(gpa, &board, &set);
    defer report.free();
    try std.testing.expect(report.passed());
    try std.testing.expectEqual(@as(usize, 0), report.issues.len);
}
