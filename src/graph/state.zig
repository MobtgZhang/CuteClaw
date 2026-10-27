//! 执行状态与检查点：节点结果、artifact 绑定、用量统计与可恢复的续跑契约。
//!
//! 三段必须分开：可变的运行状态（results/usage）、已解析的执行语义（graph）、
//! 共享用量（usage）。检查点持久化前两者，宿主重建能力实现后即可续跑。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const graph = @import("graph.zig");
const constraints = @import("../design/constraints.zig");

const Allocator = std.mem.Allocator;

pub const StateError = error{
    UnknownNode,
    UnresolvedBinding,
    InvalidState,
    OutOfMemory,
};

pub const NodeResult = struct {
    node_id: []const u8,
    ok: bool,
    output: std.json.Value = .null,
    /// 实测（measured）与推断（inferred）必须区分：决定是否继续工作的结论必须可证明。
    measured: bool = false,
    attempts: usize = 1,
    failure: []const u8 = "",
    /// 条件路由没有选中的分支：不执行，也不计入 fan-in 的进多少出多少。
    skipped: bool = false,

    pub fn free(self: *const NodeResult, gpa: Allocator) void {
        gpa.free(self.node_id);
        ju.freeJsonValue(gpa, self.output);
        gpa.free(self.failure);
    }
};

pub const Usage = struct {
    tool_calls: usize = 0,
    tool_errors: usize = 0,
    iterations: usize = 0,
    layers_executed: usize = 0,
    fan_out_batches: usize = 0,
};

pub const State = struct {
    gpa: Allocator,
    graph: *graph.Graph,
    /// restore 时图由 State 自己分配：调用方无法再持有它，必须由 deinit 释放。
    owned_graph: ?*graph.Graph = null,
    results: std.StringHashMap(NodeResult),
    artifacts: std.StringHashMap([]const u8),
    usage: Usage = .{},

    pub fn init(gpa: Allocator, g: *graph.Graph) State {
        return .{
            .gpa = gpa,
            .graph = g,
            .results = std.StringHashMap(NodeResult).init(gpa),
            .artifacts = std.StringHashMap([]const u8).init(gpa),
        };
    }

    pub fn deinit(self: *State) void {
        var it = self.results.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.free(self.gpa);
        }
        self.results.deinit();

        var art = self.artifacts.iterator();
        while (art.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.artifacts.deinit();

        if (self.owned_graph) |g| {
            g.deinit();
            self.gpa.destroy(g);
        }
    }

    pub fn record(self: *State, node_id: []const u8, result: NodeResult) !void {
        const entry = try self.results.getOrPut(node_id);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.gpa.dupe(u8, node_id);
            entry.value_ptr.* = .{
                // key 与 value 各自持有独立副本：deinit 会分别释放，不能共用同一块内存。
                .node_id = try self.gpa.dupe(u8, node_id),
                .ok = result.ok,
                .output = try ju.copyJsonValue(self.gpa, result.output),
                .measured = result.measured,
                .attempts = result.attempts,
                .failure = try self.gpa.dupe(u8, result.failure),
                .skipped = result.skipped,
            };
            return;
        }

        const existing = entry.value_ptr.*;
        const attempts = existing.attempts + result.attempts;
        const failure = try self.gpa.dupe(u8, result.failure);
        errdefer self.gpa.free(failure);
        const output = try ju.copyJsonValue(self.gpa, result.output);
        errdefer ju.freeJsonValue(self.gpa, output);

        ju.freeJsonValue(self.gpa, existing.output);
        self.gpa.free(existing.failure);
        entry.value_ptr.* = .{
            .node_id = existing.node_id,
            .ok = result.ok,
            .output = output,
            .measured = result.measured,
            .attempts = attempts,
            .failure = failure,
            .skipped = result.skipped or existing.skipped,
        };
    }

    pub fn get(self: *const State, node_id: []const u8) ?NodeResult {
        return self.results.get(node_id);
    }

    /// 定向重做：丢弃某个节点的结果，让它在下一轮重新执行。
    pub fn forget(self: *State, node_id: []const u8) bool {
        const entry = self.results.getEntry(node_id) orelse return false;
        // 先取出再释放：remove 会按内容比较 key，释放后它就是悬垂指针。
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        _ = self.results.remove(node_id);
        self.gpa.free(key);
        value.free(self.gpa);
        return true;
    }

    /// 从已记录结果收集度量：capability 输出里的 kind/value/ref/measured 字段。
    pub fn measurements(self: *State, node: graph.Node) ![]graph.Measurement {
        var out: std.ArrayList(graph.Measurement) = .empty;
        errdefer out.deinit(
            self.gpa,
        );

        for (node.depends_on) |d| {
            const r = self.results.get(d) orelse continue;
            if (!r.ok or r.output != .object) continue;
            const o = r.output.object;
            const kind = constraints.kindFromString(ju.objStr(o, "kind")) orelse continue;
            const value_v = o.get("value");
            if (value_v == null) continue;
            // JSON 里的整数与浮点都要能度量：`3` 解析成 .integer，不能只认 .float。
            if (value_v.? != .integer and value_v.? != .float) continue;
            try out.append(self.gpa, .{
                .kind = kind,
                .value = graph.numberFromValue(value_v),
                .ref = try self.gpa.dupe(u8, ju.objStr(o, "ref")),
                .measured = r.measured,
            });
        }

        return out.toOwnedSlice(
            self.gpa,
        );
    }

    pub fn completed(self: *const State, node_id: []const u8) bool {
        const r = self.results.get(node_id) orelse return false;
        return r.ok;
    }

    pub fn putArtifact(self: *State, key: []const u8, value: []const u8) !void {
        const entry = try self.artifacts.getOrPut(key);
        if (entry.found_existing) {
            self.gpa.free(entry.value_ptr.*);
            entry.value_ptr.* = try self.gpa.dupe(u8, value);
            return;
        }
        entry.key_ptr.* = try self.gpa.dupe(u8, key);
        entry.value_ptr.* = try self.gpa.dupe(u8, value);
    }

    pub fn artifact(self: *const State, key: []const u8) ?[]const u8 {
        return self.artifacts.get(key);
    }

    /// 结构化参数绑定：`$expr` 指向 input、上游节点输出或 artifact。
    /// 读取上游输出必须显式声明依赖，否则解析失败而不是静默取值。
    pub fn resolve(self: *const State, node: graph.Node) !std.json.Value {
        if (node.payload == .object) {
            const expr_v = node.payload.object.get("$expr");
            if (expr_v) |e| {
                if (e == .string) return resolveExpr(self, node, e.string);
            }
        }
        return ju.copyJsonValue(self.gpa, node.payload);
    }

    fn resolveExpr(self: *const State, node: graph.Node, expr: []const u8) !std.json.Value {
        if (std.mem.startsWith(u8, expr, "input.")) {
            const key = expr[6..];
            if (self.graph.input != .object) return error.UnresolvedBinding;
            const v = self.graph.input.object.get(key) orelse return error.UnresolvedBinding;
            return ju.copyJsonValue(self.gpa, v);
        }

        if (std.mem.startsWith(u8, expr, "node.")) {
            const rest = expr[5..];
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return error.UnresolvedBinding;
            const target = rest[0..dot];
            const field = rest[dot + 1 ..];
            // 显式依赖检查：读取别的节点输出必须先声明依赖。
            var declared = false;
            for (node.depends_on) |d| {
                if (std.mem.eql(u8, d, target)) declared = true;
            }
            if (!declared) return error.UnresolvedBinding;
            const r = self.results.get(target) orelse return error.UnresolvedBinding;
            if (!r.ok) return error.UnresolvedBinding;
            // `node.<id>.output` 取整个输出；`node.<id>.<field>` 取其中的某个字段。
            if (std.mem.eql(u8, field, "output")) return ju.copyJsonValue(self.gpa, r.output);
            if (r.output != .object) return error.UnresolvedBinding;
            const v = r.output.object.get(field) orelse return error.UnresolvedBinding;
            return ju.copyJsonValue(self.gpa, v);
        }

        if (std.mem.startsWith(u8, expr, "artifact.")) {
            const key = expr[9..];
            const value = self.artifacts.get(key) orelse return error.UnresolvedBinding;
            return ju.strVal(self.gpa, value);
        }

        return error.UnresolvedBinding;
    }

    /// 完整性检查：fan-in 层必须「进多少出多少」，静默丢条目比报告漏项更糟。
    pub fn completeness(self: *const State, node: graph.Node) !usize {
        var in_count: usize = 0;
        for (node.depends_on) |d| {
            const r = self.results.get(d) orelse continue;
            if (r.ok and !r.skipped) in_count += 1;
        }
        const r = self.results.get(node.id) orelse return error.InvalidState;
        var out_count: usize = 0;
        if (r.output == .object) {
            out_count = ju.objNum(r.output.object, "count");
        } else if (r.output == .array) {
            out_count = r.output.array.items.len;
        }
        if (out_count != in_count) return error.InvalidState;
        return out_count;
    }

    /// 检查点：可变的运行状态 + 已解析的执行语义 + 共享用量，三段分开。
    pub fn checkpoint(self: *const State) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "graph", try self.graph.toJson());

        var results = ju.newArr(self.gpa);
        var it = self.results.iterator();
        while (it.next()) |e| {
            var item = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &item.object, "node_id", try ju.strVal(self.gpa, e.key_ptr.*));
            try ju.putKey(self.gpa, &item.object, "ok", .{ .bool = e.value_ptr.ok });
            try ju.putKey(self.gpa, &item.object, "measured", .{ .bool = e.value_ptr.measured });
            try ju.putKey(self.gpa, &item.object, "attempts", .{ .integer = @intCast(e.value_ptr.attempts) });
            try ju.putKey(self.gpa, &item.object, "failure", try ju.strVal(self.gpa, e.value_ptr.failure));
            try ju.putKey(self.gpa, &item.object, "skipped", .{ .bool = e.value_ptr.skipped });
            try ju.putKey(self.gpa, &item.object, "output", try ju.copyJsonValue(self.gpa, e.value_ptr.output));
            try results.array.append(item);
        }
        try ju.putKey(self.gpa, &obj.object, "results", results);

        var artifacts = ju.newObj(self.gpa);
        var art = self.artifacts.iterator();
        while (art.next()) |e| try ju.putKey(self.gpa, &artifacts.object, e.key_ptr.*, try ju.strVal(self.gpa, e.value_ptr.*));
        try ju.putKey(self.gpa, &obj.object, "artifacts", artifacts);

        var usage = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &usage.object, "tool_calls", .{ .integer = @intCast(self.usage.tool_calls) });
        try ju.putKey(self.gpa, &usage.object, "tool_errors", .{ .integer = @intCast(self.usage.tool_errors) });
        try ju.putKey(self.gpa, &usage.object, "iterations", .{ .integer = @intCast(self.usage.iterations) });
        try ju.putKey(self.gpa, &usage.object, "layers_executed", .{ .integer = @intCast(self.usage.layers_executed) });
        try ju.putKey(self.gpa, &obj.object, "usage", usage);

        // 续跑契约必须写清楚还剩哪些节点：检查点不是「跑完了」的证明，
        // 只是「哪些结果已经存在、哪些还欠着」。
        var pending = ju.newArr(self.gpa);
        for (self.graph.nodes.items) |n| {
            if (self.completed(n.id)) continue;
            try pending.array.append(try ju.strVal(self.gpa, n.id));
        }
        try ju.putKey(self.gpa, &obj.object, "pending", pending);
        return obj;
    }

    /// 从检查点恢复：图与已完成结果重建，能力实现由宿主重新装配。
    pub fn restore(gpa: Allocator, text: []const u8) !State {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidState;
        const root = parsed.value.object;

        const graph_v = root.get("graph") orelse return error.InvalidState;
        const g = try gpa.create(graph.Graph);
        errdefer gpa.destroy(g);
        g.* = try graph.Graph.fromJson(gpa, graph_v);
        errdefer g.deinit();

        var state = State.init(gpa, g);
        state.owned_graph = g;
        errdefer state.deinit();

        if (root.get("results")) |r_v| {
            if (r_v == .array) {
                for (r_v.array.items) |item| {
                    if (item != .object) continue;
                    const o = item.object;
                    try state.record(ju.objStr(o, "node_id"), .{
                        .node_id = ju.objStr(o, "node_id"),
                        .ok = ju.objGet(o, "ok") != null and ju.objGet(o, "ok").? == .bool and ju.objGet(o, "ok").?.bool,
                        .output = o.get("output") orelse .null,
                        .measured = ju.objGet(o, "measured") != null and ju.objGet(o, "measured").? == .bool and ju.objGet(o, "measured").?.bool,
                        .attempts = ju.objNum(o, "attempts"),
                        .failure = ju.objStr(o, "failure"),
                    });
                }
            }
        }

        if (root.get("artifacts")) |a_v| {
            if (a_v == .object) {
                var it = a_v.object.iterator();
                while (it.next()) |e| try state.putArtifact(e.key_ptr.*, ju.objStr(a_v.object, e.key_ptr.*));
            }
        }

        if (root.get("usage")) |u_v| {
            if (u_v == .object) {
                state.usage.tool_calls = ju.objNum(u_v.object, "tool_calls");
                state.usage.tool_errors = ju.objNum(u_v.object, "tool_errors");
                state.usage.iterations = ju.objNum(u_v.object, "iterations");
                state.usage.layers_executed = ju.objNum(u_v.object, "layers_executed");
            }
        }

        return state;
    }
};

test "state resolves structured bindings" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "bindings");
    defer g.deinit();
    const input = try ju.parseValue(gpa, "{\"rubric\":\"auth must be checked per route\"}");
    defer ju.freeJsonValue(gpa, input);
    // 图持有自己的副本：测试释放 input 后，g.deinit() 释放的必须是这份拷贝。
    g.input = try ju.copyJsonValue(gpa, input);

    try g.add(.{ .id = "rubric", .capability = "define_rubric" });
    const read_output = try ju.parseValue(gpa, "{\"$expr\":\"node.rubric.output\"}");
    defer ju.freeJsonValue(gpa, read_output);
    try g.add(.{ .id = "audit", .capability = "audit", .depends_on = &.{"rubric"}, .payload = read_output });

    var st = State.init(gpa, &g);
    defer st.deinit();

    // 未记录上游结果前解析必须失败：不能静默取值。
    try std.testing.expectError(error.UnresolvedBinding, st.resolve(g.nodeAt(1)));

    const out = try ju.parseValue(gpa, "{\"count\":1}");
    defer ju.freeJsonValue(gpa, out);
    try st.record("rubric", .{ .node_id = "rubric", .ok = true, .output = out, .measured = true });

    const resolved = try st.resolve(g.nodeAt(1));
    defer ju.freeJsonValue(gpa, resolved);
    try std.testing.expect(resolved == .object);
    try std.testing.expectEqual(@as(usize, 1), ju.objNum(resolved.object, "count"));

    // input.<key> 走的是图输入，不需要上游结果。
    const from_input = try st.resolveExpr(g.nodeAt(1), "input.rubric");
    defer ju.freeJsonValue(gpa, from_input);
    try std.testing.expect(from_input == .string);
    try std.testing.expectEqualStrings("auth must be checked per route", from_input.string);
}

test "reading an undeclared upstream output fails" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "undeclared");
    defer g.deinit();
    try g.add(.{ .id = "a", .capability = "x" });
    const undeclared = try ju.parseValue(gpa, "{\"$expr\":\"node.a.output\"}");
    defer ju.freeJsonValue(gpa, undeclared);
    try g.add(.{ .id = "b", .capability = "y", .payload = undeclared });

    var st = State.init(gpa, &g);
    defer st.deinit();
    try st.record("a", .{ .node_id = "a", .ok = true, .output = .{ .integer = 1 } });
    try std.testing.expectError(error.UnresolvedBinding, st.resolve(g.nodeAt(1)));
}

test "fan-in completeness check counts in and out" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "fan-in");
    defer g.deinit();
    try g.add(.{ .id = "a", .capability = "audit", .kind = .fan_out });
    try g.add(.{ .id = "b", .capability = "audit", .kind = .fan_out });
    try g.add(.{ .id = "merge", .capability = "consolidate", .kind = .fan_in, .batch = 25, .depends_on = &.{ "a", "b" } });

    var st = State.init(gpa, &g);
    defer st.deinit();
    try st.record("a", .{ .node_id = "a", .ok = true, .measured = true });
    try st.record("b", .{ .node_id = "b", .ok = true, .measured = true });

    const short = try ju.parseValue(gpa, "{\"count\":1}");
    defer ju.freeJsonValue(gpa, short);
    try st.record("merge", .{ .node_id = "merge", .ok = true, .output = short, .measured = true });
    try std.testing.expectError(error.InvalidState, st.completeness(g.nodeAt(2)));

    const full = try ju.parseValue(gpa, "{\"count\":2}");
    defer ju.freeJsonValue(gpa, full);
    try st.record("merge", .{ .node_id = "merge", .ok = true, .output = full, .measured = true });
    try std.testing.expectEqual(@as(usize, 2), try st.completeness(g.nodeAt(2)));
}

test "checkpoint roundtrip keeps usage and results" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "pcb-design-review", "review");
    defer g.deinit();
    try g.add(.{ .id = "parse", .capability = "read_kicad", .writes = "board" });

    var st = State.init(gpa, &g);
    defer st.deinit();
    const out = try ju.parseValue(gpa, "{\"components\":184}");
    defer ju.freeJsonValue(gpa, out);
    try st.record("parse", .{ .node_id = "parse", .ok = true, .output = out, .measured = true });
    try st.putArtifact("board", "hardware/rev2/board.kicad_pcb");
    st.usage.tool_calls = 3;
    st.usage.layers_executed = 1;

    const cp = try st.checkpoint();
    defer ju.freeJsonValue(gpa, cp);
    const text = try ju.stringifyAlloc(gpa, cp);
    defer gpa.free(text);

    var restored = try State.restore(gpa, text);
    defer restored.deinit();

    try std.testing.expect(restored.completed("parse"));
    try std.testing.expectEqual(@as(usize, 3), restored.usage.tool_calls);
    try std.testing.expectEqualStrings("hardware/rev2/board.kicad_pcb", restored.artifact("board").?);
    try std.testing.expectEqual(@as(usize, 184), ju.objNum(restored.get("parse").?.output.object, "components"));
}
