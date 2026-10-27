//! 门（Gate）：不可协商的工程原则。硬门不可被自进化改写（与 guardrails 一致）。
//!
//! 这些规则来自 GitHub 上真实 PCB/CAD 工程 skill 的共识：
//! - 绿板不等于正确：每个阶段结束都要一次只读的对抗性审查，重新推导数字而不是读取它。
//! - 实测而非推断：决定是否继续工作的结论必须可证明，"大概不支持"不是发现。
//! - 先校验工具再校验结果：几何变换必须用已知非对称物体标定。
//! - 终止条件必须在循环开始前写下来。
//! - fan-in 必须进多少出多少，静默丢条目比报告漏项更糟。
//! - 验证不能确认自己的合成结果。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const constraints = @import("../design/constraints.zig");
const graph = @import("graph.zig");

const Allocator = std.mem.Allocator;

pub const GateError = error{
    ImmutableGate,
    GateFailed,
    InvalidGate,
    OutOfMemory,
};

pub const Gate = struct {
    id: []const u8,
    /// null 表示适用于任何度量：这类门只看来源（实测还是推断），不比较数值。
    kind: ?constraints.Kind = null,
    limit: f64,
    direction: constraints.Direction,
    severity: constraints.Severity,
    /// 只接受实测值：推断值不能通过此门。
    measured_only: bool = false,
    /// 硬门不可编辑；自进化只能改软门。
    editable: bool = false,

    pub fn free(self: *const Gate, gpa: Allocator) void {
        gpa.free(self.id);
    }
};

pub const GateFailure = struct {
    gate_id: []const u8,
    ref: []const u8,
    measured: f64,
    limit: f64,
    severity: constraints.Severity,
    inferred: bool,

    pub fn free(self: *const GateFailure, gpa: Allocator) void {
        gpa.free(self.gate_id);
        gpa.free(self.ref);
    }
};

pub const GateReport = struct {
    gpa: Allocator,
    failures: []GateFailure,
    hard_count: usize,

    pub fn passed(self: *const GateReport) bool {
        return self.hard_count == 0;
    }

    pub fn free(self: *const GateReport) void {
        for (self.failures) |f| f.free(self.gpa);
        self.gpa.free(self.failures);
    }
};

pub const GateSet = struct {
    gpa: Allocator,
    gates: std.ArrayList(Gate),

    pub fn init(gpa: Allocator) GateSet {
        return .{ .gpa = gpa, .gates = .empty };
    }

    pub fn deinit(self: *GateSet) void {
        for (self.gates.items) |g| g.free(self.gpa);
        self.gates.deinit(self.gpa);
    }

    pub fn add(self: *GateSet, gate: Gate) !void {
        if (gate.id.len == 0) return error.InvalidGate;
        var copy = gate;
        errdefer copy.free(self.gpa);
        copy.id = try self.gpa.dupe(u8, gate.id);
        try self.gates.append(self.gpa, copy);
    }

    /// 自进化只能改软门；硬门直接拒绝。
    pub fn proposeEdit(self: *GateSet, id: []const u8, limit: f64) !void {
        for (self.gates.items, 0..) |g, i| {
            if (!std.mem.eql(u8, g.id, id)) continue;
            if (!g.editable) return error.ImmutableGate;
            const entry = &self.gates.items[i];
            entry.limit = limit;
            return;
        }
        return error.InvalidGate;
    }

    pub fn evaluate(self: *const GateSet, measurements: []const graph.Measurement) !GateReport {
        var out: std.ArrayList(GateFailure) = .empty;
        errdefer {
            for (out.items) |f| f.free(self.gpa);
            out.deinit(
                self.gpa,
            );
        }

        var hard: usize = 0;
        for (self.gates.items) |g| {
            for (measurements) |m| {
                // 来源型门不比较数值：它只回答「这个数字是量出来的还是猜出来的」。
                if (g.kind == null) {
                    if (g.measured_only and !m.measured) {
                        try out.append(self.gpa, .{
                            .gate_id = try self.gpa.dupe(u8, g.id),
                            .ref = try self.gpa.dupe(u8, m.ref),
                            .measured = m.value,
                            .limit = g.limit,
                            .severity = g.severity,
                            .inferred = true,
                        });
                        if (g.severity == .hard) hard += 1;
                    }
                    continue;
                }
                const gate_kind = g.kind orelse continue;
                if (m.kind != gate_kind) continue;
                // 先判定来源：推断值不能通过 measured-only 门，即使数值本身落在限值内。
                if (g.measured_only and !m.measured) {
                    try out.append(self.gpa, .{
                        .gate_id = try self.gpa.dupe(u8, g.id),
                        .ref = try self.gpa.dupe(u8, m.ref),
                        .measured = m.value,
                        .limit = g.limit,
                        .severity = g.severity,
                        .inferred = true,
                    });
                    if (g.severity == .hard) hard += 1;
                    continue;
                }
                if (constraints.satisfies(.{
                    .id = g.id,
                    .kind = gate_kind,
                    .limit = g.limit,
                    .direction = g.direction,
                    .severity = g.severity,
                }, m.value)) continue;

                try out.append(self.gpa, .{
                    .gate_id = try self.gpa.dupe(u8, g.id),
                    .ref = try self.gpa.dupe(u8, m.ref),
                    .measured = m.value,
                    .limit = g.limit,
                    .severity = g.severity,
                    .inferred = false,
                });
                if (g.severity == .hard) hard += 1;
            }
        }

        return .{ .gpa = self.gpa, .failures = try out.toOwnedSlice(
            self.gpa,
        ), .hard_count = hard };
    }
};

/// 内置硬门：DRC 必须为零、结论必须实测、fan-in 必须完整、变换必须先标定。
/// 内置硬门：DRC 必须为零、外壳不能有负间隙、结论必须实测。
/// fan-in 完整性与「先标定再变换」是结构性规则，由对抗性审查和执行器保证，
/// 不能靠一个数值门来表达——把计数当成分数用会制造假失败。
pub fn builtinHardGates(gpa: Allocator) !GateSet {
    var set = GateSet.init(gpa);
    try set.add(.{ .id = "drc_errors", .kind = .drc_errors, .limit = 0, .direction = .max, .severity = .hard, .measured_only = true });
    try set.add(.{ .id = "fit_clearance", .kind = .fit_clearance, .limit = 0, .direction = .min, .severity = .hard, .measured_only = true });
    try set.add(.{ .id = "measured_only", .kind = null, .limit = 0, .direction = .max, .severity = .hard, .measured_only = true });
    return set;
}

pub const ReviewViolation = struct {
    node_id: []const u8,
    rule: []const u8,

    pub fn free(self: *const ReviewViolation, gpa: Allocator) void {
        gpa.free(self.node_id);
        gpa.free(self.rule);
    }
};

/// 对抗性审查：只读、单遍，检查图本身是否满足工程原则。
pub fn adversarialReview(g: *const graph.Graph) ![]ReviewViolation {
    var out: std.ArrayList(ReviewViolation) = .empty;
    errdefer {
        for (out.items) |v| v.free(g.gpa);
        out.deinit(g.gpa);
    }

    if (g.termination == null) {
        try out.append(g.gpa, .{
            .node_id = try g.gpa.dupe(u8, "graph"),
            .rule = try g.gpa.dupe(u8, "termination criterion must be written before the loop starts"),
        });
    }

    for (g.nodes.items) |n| {
        // 验证不能确认自己的合成结果。
        if (n.kind == .verify) {
            for (n.depends_on) |d| {
                const di = g.find(d) orelse continue;
                if (g.nodeAt(di).kind == .fan_in) {
                    try out.append(g.gpa, .{
                        .node_id = try g.gpa.dupe(u8, n.id),
                        .rule = try g.gpa.dupe(u8, "verification cannot ratify its own synthesis"),
                    });
                }
            }
            if (!n.rederive) {
                try out.append(g.gpa, .{
                    .node_id = try g.gpa.dupe(u8, n.id),
                    .rule = try g.gpa.dupe(u8, "verify node must re-derive from source"),
                });
            }
        }

        // 使用几何变换的测量节点必须先经过标定节点。
        // 标定节点本身不算被标定的对象：它自己就是基准。
        if (n.kind == .work and std.mem.indexOf(u8, n.capability, "transform") != null and std.mem.indexOf(u8, n.capability, "calibrate") == null) {
            var calibrated = false;
            for (n.depends_on) |d| {
                const di = g.find(d) orelse continue;
                if (std.mem.indexOf(u8, g.nodeAt(di).capability, "calibrate") != null) calibrated = true;
            }
            if (!calibrated) {
                try out.append(g.gpa, .{
                    .node_id = try g.gpa.dupe(u8, n.id),
                    .rule = try g.gpa.dupe(u8, "geometric transform must be calibrated against a known asymmetric object"),
                });
            }
        }

        // 决定是否继续工作的结论必须实测：gate 节点必须来自 verify 或实测工作节点。
        if (n.kind == .gate and n.depends_on.len == 0) {
            try out.append(g.gpa, .{
                .node_id = try g.gpa.dupe(u8, n.id),
                .rule = try g.gpa.dupe(u8, "gate must read a measured result, not an assumption"),
            });
        }
    }

    return out.toOwnedSlice(g.gpa);
}

test "hard gates cannot be edited by self-evolution" {
    const gpa = std.testing.allocator;
    var gates = try builtinHardGates(gpa);
    defer gates.deinit();

    try std.testing.expectError(error.ImmutableGate, gates.proposeEdit("drc_errors", 5));

    var soft = GateSet.init(gpa);
    defer soft.deinit();
    try soft.add(.{ .id = "rat_length", .kind = .rat_length, .limit = 900, .direction = .max, .severity = .soft, .editable = true });
    try soft.proposeEdit("rat_length", 850);
    try std.testing.expectApproxEqAbs(@as(f64, 850.0), soft.gates.items[0].limit, 0.0001);
}

test "inferred values cannot pass a measured-only gate" {
    const gpa = std.testing.allocator;
    var gates = GateSet.init(gpa);
    defer gates.deinit();
    try gates.add(.{ .id = "drc_errors", .kind = .drc_errors, .limit = 0, .direction = .max, .severity = .hard, .measured_only = true });

    const inferred = [_]graph.Measurement{.{ .kind = .drc_errors, .value = 0, .ref = "assumed", .measured = false }};
    const report = try gates.evaluate(&inferred);
    defer report.free();
    try std.testing.expect(!report.passed());
    try std.testing.expect(report.failures[0].inferred);

    // 来源型门（kind = null）适用于任何度量：计数值本身是实测的，不能因为数值大于限值就判失败。
    var builtin = try builtinHardGates(gpa);
    defer builtin.deinit();
    const counted = [_]graph.Measurement{.{ .kind = .iterations, .value = 2, .ref = "fan-in", .measured = true }};
    const counted_report = try builtin.evaluate(&counted);
    defer counted_report.free();
    try std.testing.expect(counted_report.passed());

    const guessed = [_]graph.Measurement{.{ .kind = .iterations, .value = 0, .ref = "fan-in", .measured = false }};
    const guessed_report = try builtin.evaluate(&guessed);
    defer guessed_report.free();
    try std.testing.expect(!guessed_report.passed());
    try std.testing.expectEqual(@as(usize, 1), guessed_report.hard_count);

    const measured = [_]graph.Measurement{.{ .kind = .drc_errors, .value = 0, .ref = "parsed gerber", .measured = true }};
    const ok = try gates.evaluate(&measured);
    defer ok.free();
    try std.testing.expect(ok.passed());
}

test "adversarial review rejects self-ratifying verification" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "review");
    defer g.deinit();
    try g.add(.{ .id = "batch", .capability = "audit", .kind = .fan_out });
    try g.add(.{ .id = "merge", .capability = "consolidate", .kind = .fan_in, .depends_on = &.{"batch"} });
    try g.add(.{ .id = "verify", .capability = "rederive", .kind = .verify, .depends_on = &.{"merge"} });

    const violations = try adversarialReview(&g);
    defer {
        for (violations) |v| v.free(gpa);
        gpa.free(violations);
    }
    try std.testing.expect(violations.len >= 2); // 缺终止条件 + 自确认 + 未重新推导

    var good = graph.Graph.init(gpa, "graph-orchestrator", "clean");
    defer good.deinit();
    try good.setTermination(.{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 3, .criterion = "hard violations must be zero" });
    try good.add(.{ .id = "source", .capability = "read_source", .kind = .work });
    try good.add(.{ .id = "verify", .capability = "rederive", .kind = .verify, .rederive = true, .depends_on = &.{"source"} });
    const clean = try adversarialReview(&good);
    defer {
        for (clean) |v| v.free(gpa);
        gpa.free(clean);
    }
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

test "transform nodes need a calibration gate" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "calibration");
    defer g.deinit();
    try g.setTermination(.{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 2, .criterion = "zero" });
    try g.add(.{ .id = "measure", .capability = "apply_transform", .kind = .work });

    const violations = try adversarialReview(&g);
    defer {
        for (violations) |v| v.free(gpa);
        gpa.free(violations);
    }
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("measure", violations[0].node_id);
}
