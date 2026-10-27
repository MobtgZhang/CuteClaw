//! 图执行核（Graph Flow / Graph Loop）：把设计任务表达成能力节点 DAG。
//!
//! 依赖审计区分「叙述上的先后」与「真正的数据依赖」：只有后者构成边，
//! 因此可并行的工作不会被排成串行链。共享写入与破坏性操作产生隐藏边，
//! 即使没有数据流也必须排序。终止条件必须在循环开始前写下来。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const constraints = @import("../design/constraints.zig");

const Allocator = std.mem.Allocator;

pub const GraphError = error{
    DuplicateNodeId,
    UnknownDependency,
    CycleDetected,
    MissingTermination,
    SelfVerification,
    IrreversibleNeedsApproval,
    InvalidNode,
    OutOfMemory,
};

/// 一次度量：`measured` 为 false 表示推断值，不能通过 measured-only 门。
pub const Measurement = struct {
    kind: constraints.Kind,
    value: f64,
    ref: []const u8,
    measured: bool = true,
};

pub const Tier = enum { cheap, standard, strong };
pub const Risk = enum { low, medium, high, irreversible };
pub const NodeKind = enum { work, fan_out, fan_in, gate, verify, approval };

pub fn tierFromString(s: []const u8) ?Tier {
    if (std.meta.stringToEnum(Tier, s)) |t| return t;
    return null;
}

pub fn riskFromString(s: []const u8) ?Risk {
    if (std.meta.stringToEnum(Risk, s)) |r| return r;
    return null;
}

pub fn kindFromString(s: []const u8) ?NodeKind {
    if (std.meta.stringToEnum(NodeKind, s)) |k| return k;
    return null;
}

pub fn tierLabel(t: Tier) []const u8 {
    return @tagName(t);
}

pub fn riskLabel(r: Risk) []const u8 {
    return @tagName(r);
}

pub fn kindLabel(k: NodeKind) []const u8 {
    return @tagName(k);
}

/// 终止条件：先写下来，再开始循环。没有它，验证环节会自我确认并无限循环。
pub const Termination = struct {
    kind: constraints.Kind,
    limit: f64,
    direction: constraints.Direction,
    max_iterations: usize,
    criterion: []const u8,

    pub fn free(self: *const Termination, gpa: Allocator) void {
        gpa.free(self.criterion);
    }

    pub fn satisfied(self: *const Termination, value: f64) bool {
        return constraints.satisfies(.{
            .id = "termination",
            .kind = self.kind,
            .limit = self.limit,
            .direction = self.direction,
            .severity = .hard,
        }, value);
    }

    pub fn toJson(self: *const Termination, gpa: Allocator) !std.json.Value {
        var obj = ju.newObj(gpa);
        try ju.putKey(gpa, &obj.object, "kind", try ju.strVal(gpa, @tagName(self.kind)));
        try ju.putKey(gpa, &obj.object, "limit", .{ .float = self.limit });
        try ju.putKey(gpa, &obj.object, "direction", try ju.strVal(gpa, @tagName(self.direction)));
        try ju.putKey(gpa, &obj.object, "max_iterations", .{ .integer = @intCast(self.max_iterations) });
        try ju.putKey(gpa, &obj.object, "criterion", try ju.strVal(gpa, self.criterion));
        return obj;
    }
};

pub const Node = struct {
    id: []const u8,
    capability: []const u8,
    kind: NodeKind = .work,
    tier: Tier = .standard,
    risk: Risk = .low,
    skill: []const u8 = "",
    phase: usize = 0,
    depends_on: []const []const u8 = &.{},
    /// 结构化参数绑定：`$expr` 指向 input / 上游节点输出 / artifact。
    payload: std.json.Value = .null,
    /// 写入的 artifact 键；相同键的节点必须排序（隐藏边）。
    writes: []const u8 = "",
    /// 验证节点必须从源数据重新推导，不能读取上游合成的结论。
    rederive: bool = false,
    /// gate 失败时的定向重做目标（Graph Loop 的回边）。
    retry_target: []const u8 = "",
    /// fan-in 分层合并批大小；超过批大小会丢细节。
    batch: usize = 0,
    /// 面向外部或不可逆的动作：必须停在人工审批门前。
    irreversible: bool = false,
    /// fan-out 节点在干净上下文里执行：读过的东西不能污染下一项的判断。
    fresh_context: bool = false,
    /// 0 表示宿主没有 subagent 工具：该节点降级为分批工具调用，而不是并行子代理。
    max_parallel: usize = 0,

    pub fn free(self: *const Node, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.capability);
        gpa.free(self.skill);
        for (self.depends_on) |d| gpa.free(d);
        gpa.free(self.depends_on);
        gpa.free(self.writes);
        gpa.free(self.retry_target);
        ju.freeJsonValue(gpa, self.payload);
    }

    pub fn toJson(self: *const Node, gpa: Allocator) !std.json.Value {
        var obj = ju.newObj(gpa);
        try ju.putKey(gpa, &obj.object, "id", try ju.strVal(gpa, self.id));
        try ju.putKey(gpa, &obj.object, "capability", try ju.strVal(gpa, self.capability));
        try ju.putKey(gpa, &obj.object, "kind", try ju.strVal(gpa, kindLabel(self.kind)));
        try ju.putKey(gpa, &obj.object, "tier", try ju.strVal(gpa, tierLabel(self.tier)));
        try ju.putKey(gpa, &obj.object, "risk", try ju.strVal(gpa, riskLabel(self.risk)));
        try ju.putKey(gpa, &obj.object, "skill", try ju.strVal(gpa, self.skill));
        try ju.putKey(gpa, &obj.object, "phase", .{ .integer = @intCast(self.phase) });
        var deps = ju.newArr(gpa);
        for (self.depends_on) |d| try deps.array.append(try ju.strVal(gpa, d));
        try ju.putKey(gpa, &obj.object, "depends_on", deps);
        try ju.putKey(gpa, &obj.object, "payload", try ju.copyJsonValue(gpa, self.payload));
        try ju.putKey(gpa, &obj.object, "writes", try ju.strVal(gpa, self.writes));
        try ju.putKey(gpa, &obj.object, "rederive", .{ .bool = self.rederive });
        try ju.putKey(gpa, &obj.object, "retry_target", try ju.strVal(gpa, self.retry_target));
        try ju.putKey(gpa, &obj.object, "batch", .{ .integer = @intCast(self.batch) });
        try ju.putKey(gpa, &obj.object, "irreversible", .{ .bool = self.irreversible });
        try ju.putKey(gpa, &obj.object, "fresh_context", .{ .bool = self.fresh_context });
        try ju.putKey(gpa, &obj.object, "max_parallel", .{ .integer = @intCast(self.max_parallel) });
        return obj;
    }
};

pub const HiddenEdge = struct {
    from: usize,
    to: usize,
    reason: []const u8,
};

pub const Graph = struct {
    gpa: Allocator,
    skill: []const u8,
    name: []const u8,
    nodes: std.ArrayList(Node),
    input: std.json.Value = .null,
    termination: ?Termination = null,

    pub fn init(gpa: Allocator, skill: []const u8, name: []const u8) Graph {
        return .{
            .gpa = gpa,
            .skill = skill,
            .name = name,
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |n| n.free(self.gpa);
        self.nodes.deinit(self.gpa);
        if (self.termination) |t| t.free(self.gpa);
        ju.freeJsonValue(self.gpa, self.input);
    }

    pub fn add(self: *Graph, node: Node) !void {
        var copy = node;
        errdefer copy.free(self.gpa);
        copy.id = try self.gpa.dupe(u8, node.id);
        copy.capability = try self.gpa.dupe(u8, node.capability);
        copy.skill = try self.gpa.dupe(u8, node.skill);
        copy.writes = try self.gpa.dupe(u8, node.writes);
        copy.retry_target = try self.gpa.dupe(u8, node.retry_target);
        var deps: std.ArrayList([]const u8) = .empty;
        errdefer deps.deinit(
            self.gpa,
        );
        for (node.depends_on) |d| try deps.append(self.gpa, try self.gpa.dupe(u8, d));
        copy.depends_on = try deps.toOwnedSlice(
            self.gpa,
        );
        copy.payload = try ju.copyJsonValue(self.gpa, node.payload);
        try self.nodes.append(self.gpa, copy);
    }

    pub fn setTermination(self: *Graph, t: Termination) !void {
        // 先复制再释放旧值：调用方传进来的 criterion 常常正指向旧终止条件自己的内存，
        // 先 free 会让后面的 dupe 读到已释放的字节（打印出来就是乱码）。
        const criterion = try self.gpa.dupe(u8, t.criterion);
        errdefer self.gpa.free(criterion);
        if (self.termination) |old| old.free(self.gpa);
        self.termination = .{
            .kind = t.kind,
            .limit = t.limit,
            .direction = t.direction,
            .max_iterations = t.max_iterations,
            .criterion = criterion,
        };
    }

    pub fn count(self: *const Graph) usize {
        return self.nodes.items.len;
    }

    pub fn find(self: *const Graph, id: []const u8) ?usize {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.id, id)) return i;
        }
        return null;
    }

    pub fn nodeAt(self: *const Graph, i: usize) Node {
        return self.nodes.items[i];
    }

    /// 直接依赖：B 是否读取 A 的输出。
    pub fn directDependency(self: *const Graph, from: usize, to: usize) bool {
        const target = self.nodeAt(to);
        for (target.depends_on) |d| {
            if (std.mem.eql(u8, d, self.nodeAt(from).id)) return true;
        }
        return false;
    }

    /// 传递依赖：B 是否（直接或间接）读取 A 的输出。
    pub fn dependsOn(self: *const Graph, from: usize, to: usize) !bool {
        var seen = std.AutoHashMap(usize, bool).init(self.gpa);
        defer seen.deinit();
        return transitivelyDepends(self, from, to, &seen);
    }

    /// 依赖审计：两个节点之间没有数据流即为独立，可 fan-out。
    /// 隐藏边（共享写入、破坏性动作）同样是真实排序约束，不能当作独立。
    pub fn independent(self: *const Graph, a: usize, b: usize) !bool {
        if (a == b) return false;
        if (try self.hasHiddenEdge(a, b)) return false;
        return !(try self.dependsOn(a, b)) and !(try self.dependsOn(b, a));
    }

    fn hasHiddenEdge(self: *const Graph, a: usize, b: usize) !bool {
        const edges = try self.hiddenEdges();
        defer {
            for (edges) |e| self.gpa.free(e.reason);
            self.gpa.free(edges);
        }
        for (edges) |e| {
            if (e.from == a and e.to == b) return true;
            if (e.from == b and e.to == a) return true;
        }
        return false;
    }

    /// 隐藏边：共享写入与破坏性动作造成的真实排序约束。
    pub fn hiddenEdges(self: *const Graph) ![]HiddenEdge {
        var out: std.ArrayList(HiddenEdge) = .empty;
        errdefer out.deinit(
            self.gpa,
        );

        for (self.nodes.items, 0..) |a, i| {
            if (a.writes.len == 0) continue;
            for (self.nodes.items, 0..) |b, j| {
                if (j <= i) continue;
                if (b.writes.len == 0) continue;
                if (!std.mem.eql(u8, a.writes, b.writes)) continue;
                try out.append(self.gpa, .{
                    .from = i,
                    .to = j,
                    .reason = try std.fmt.allocPrint(self.gpa, "shared write: {s}", .{a.writes}),
                });
            }
        }

        for (self.nodes.items, 0..) |v, i| {
            if (v.kind != .verify) continue;
            for (self.nodes.items, 0..) |n, j| {
                if (!n.irreversible) continue;
                try out.append(self.gpa, .{
                    .from = i,
                    .to = j,
                    .reason = try std.fmt.allocPrint(self.gpa, "irreversible action {s} must follow verification {s}", .{ n.id, v.id }),
                });
            }
        }

        return out.toOwnedSlice(
            self.gpa,
        );
    }

    /// 叙述性假边：箭头只在「工作真的从 A 流到 B」时才成立。
    /// 依赖项既不产出 artifact，也没有被读取（payload 里没有 `node.<id>.` 绑定），
    /// 就只是叙述上的先后，不构成执行约束，应当删除。
    pub const NarrationEdge = struct {
        from: usize,
        to: usize,
    };

    pub fn narrationEdges(self: *const Graph) ![]NarrationEdge {
        var out: std.ArrayList(NarrationEdge) = .empty;
        errdefer out.deinit(
            self.gpa,
        );

        for (self.nodes.items, 0..) |n, idx| {
            for (n.depends_on) |d| {
                const di = self.find(d) orelse continue;
                const src = self.nodeAt(di);
                // 门、验证与 fan-in 的结论本身就是流过去的东西。
                if (src.kind == .gate or src.kind == .verify or src.kind == .fan_in) continue;
                if (src.writes.len > 0) continue;
                if (n.payload == .object) {
                    const expr_v = n.payload.object.get("$expr");
                    if (expr_v) |e| {
                        if (e == .string and readsNode(e.string, d)) continue;
                    }
                }
                try out.append(self.gpa, .{ .from = di, .to = idx });
            }
        }

        return out.toOwnedSlice(
            self.gpa,
        );
    }

    /// `$expr` 是否真的读取了某个上游节点的输出：只有工作流过去的箭头才算真实依赖。
    fn readsNode(expr: []const u8, node_id: []const u8) bool {
        if (!std.mem.startsWith(u8, expr, "node.")) return false;
        const rest = expr[5..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        return std.mem.eql(u8, rest[0..dot], node_id);
    }

    /// 工作形状决定拓扑（Google DeepMind × MIT 的停止规则）：
    /// 可拆分的任务上团队大约赢 80%，串行工作上每一种团队配置都会输。
    /// 因此先数出真正独立的任务对，再决定 fan-out 还是保持链。
    pub const Shape = struct {
        pairs: usize,
        real_edges: usize,
        narration_edges: usize,
        independent_pairs: usize,
        recommendation: []const u8,

        pub fn free(self: *const Shape, gpa: Allocator) void {
            gpa.free(self.recommendation);
        }
    };

    pub fn shapeOfWork(self: *const Graph) !Shape {
        const n = self.nodes.items.len;
        const pairs = n * (n - 1) / 2;

        var real: usize = 0;
        for (self.nodes.items) |node| real += node.depends_on.len;

        const narration = try self.narrationEdges();
        defer self.gpa.free(narration);

        var split: usize = 0;
        for (0..n) |a| {
            for (a + 1..n) |b| {
                if (try self.independent(a, b)) split += 1;
            }
        }

        var recommendation: []const u8 = "";
        if (pairs == 0) {
            recommendation = try std.fmt.allocPrint(self.gpa, "single node: a graph adds nothing, just do the work", .{});
        } else if (split == 0) {
            recommendation = try std.fmt.allocPrint(self.gpa, "sequential work: keep it a chain, fan-out would only add coordination cost", .{});
        } else if (split * 2 >= pairs) {
            recommendation = try std.fmt.allocPrint(self.gpa, "work splits: fan out {d} independent pairs, then consolidate in layers", .{split});
        } else {
            recommendation = try std.fmt.allocPrint(self.gpa, "partially splittable: fan out only the {d} independent pairs, keep the rest sequential", .{split});
        }

        return .{
            .pairs = pairs,
            .real_edges = real,
            .narration_edges = narration.len,
            .independent_pairs = split,
            .recommendation = recommendation,
        };
    }

    /// 分层（Kahn）：同一层内可并行；回边（gate 的 retry_target）不参与分层。
    pub fn layers(self: *const Graph) ![][]usize {
        var indeg = std.AutoHashMap(usize, usize).init(self.gpa);
        defer indeg.deinit();
        for (self.nodes.items, 0..) |_, i| try indeg.put(i, 0);

        for (self.nodes.items, 0..) |n, i| {
            var degree: usize = 0;
            for (n.depends_on) |d| {
                if (self.find(d)) |_| degree += 1;
            }
            try indeg.put(i, degree);
        }

        var done = std.AutoHashMap(usize, bool).init(self.gpa);
        defer done.deinit();

        var out: std.ArrayList([]usize) = .empty;
        errdefer {
            for (out.items) |l| self.gpa.free(l);
            out.deinit(
                self.gpa,
            );
        }

        var remaining: usize = self.nodes.items.len;
        while (remaining > 0) {
            var ready: std.ArrayList(usize) = .empty;
            defer ready.deinit(
                self.gpa,
            );
            for (self.nodes.items, 0..) |_, i| {
                if (done.get(i) != null) continue;
                if (indeg.get(i) == 0) try ready.append(self.gpa, i);
            }
            if (ready.items.len == 0) return error.CycleDetected;
            remaining -= ready.items.len;
            const layer = try ready.toOwnedSlice(
                self.gpa,
            );
            try out.append(self.gpa, layer);
            for (layer) |i| {
                try done.put(i, true);
                for (self.nodes.items, 0..) |n, j| {
                    if (done.get(j) != null) continue;
                    for (n.depends_on) |d| {
                        if (self.find(d) == i) try indeg.put(j, indeg.get(j).? - 1);
                    }
                }
            }
        }

        return out.toOwnedSlice(
            self.gpa,
        );
    }

    /// fan-out 分批：同一层内的独立节点按 max_parallel 分组。
    /// 宿主没有 subagent 工具时（max_parallel == 0）降级为分批工具调用，
    /// 批大小取节点自身 batch 或 default_batch，避免一次性吞下全部细节。
    pub fn fanOutBatches(self: *const Graph, default_batch: usize) ![][]usize {
        var out: std.ArrayList([]usize) = .empty;
        errdefer {
            for (out.items) |l| self.gpa.free(l);
            out.deinit(
                self.gpa,
            );
        }

        for (self.nodes.items, 0..) |n, i| {
            // 分层 fan-in：把同一层的 fan-out 结果按批合并，超过批大小会丢细节。
            if (n.kind != .fan_in) continue;
            const size = if (n.max_parallel > 0) n.max_parallel else if (n.batch > 0) n.batch else default_batch;
            if (size == 0) continue;
            var group: std.ArrayList(usize) = .empty;
            defer group.deinit(
                self.gpa,
            );
            for (n.depends_on) |d| {
                const di = self.find(d) orelse continue;
                if (self.nodeAt(di).kind == .fan_out) try group.append(self.gpa, di);
            }
            if (group.items.len == 0) try group.append(self.gpa, i);
            if (group.items.len > size) {
                // 超过批大小会丢细节：拆成多个批次，而不是一次合成。
                var start: usize = 0;
                while (start < group.items.len) {
                    const end = @min(start + size, group.items.len);
                    var slice: std.ArrayList(usize) = .empty;
                    for (group.items[start..end]) |x| try slice.append(self.gpa, x);
                    try out.append(self.gpa, try slice.toOwnedSlice(
                        self.gpa,
                    ));
                    start = end;
                }
            } else {
                try out.append(self.gpa, try group.toOwnedSlice(
                    self.gpa,
                ));
            }
        }
        return out.toOwnedSlice(
            self.gpa,
        );
    }

    /// 校验：重复 id、未知依赖、自验证、回边目标、不可逆动作前必须有审批门。
    pub fn validate(self: *const Graph) GraphError!void {
        var seen = std.StringHashMap(bool).init(self.gpa);
        defer seen.deinit();

        for (self.nodes.items, 0..) |n, idx| {
            if (n.id.len == 0) return error.InvalidNode;
            if (seen.get(n.id) != null) return error.DuplicateNodeId;
            try seen.put(n.id, true);

            for (n.depends_on) |d| {
                if (self.find(d) == null) return error.UnknownDependency;
                if (std.mem.eql(u8, d, n.id)) return error.SelfVerification;
            }

            if (n.retry_target.len > 0 and self.find(n.retry_target) == null) return error.UnknownDependency;

            if (n.irreversible) {
                var has_approval = false;
                for (self.nodes.items, 0..) |m, mi| {
                    if (m.kind != .approval) continue;
                    var seen_approval = std.AutoHashMap(usize, bool).init(self.gpa);
                    defer seen_approval.deinit();
                    if (try transitivelyDepends(self, mi, idx, &seen_approval)) {
                        has_approval = true;
                        break;
                    }
                }
                if (!has_approval) return error.IrreversibleNeedsApproval;
            }
        }
    }

    pub const Stats = struct {
        nodes: usize,
        fan_out: usize,
        fan_in: usize,
        gates: usize,
        verify: usize,
        approval: usize,
    };

    pub fn stats(self: *const Graph) Stats {
        var s: Stats = .{ .nodes = self.nodes.items.len, .fan_out = 0, .fan_in = 0, .gates = 0, .verify = 0, .approval = 0 };
        for (self.nodes.items) |n| {
            switch (n.kind) {
                .fan_out => s.fan_out += 1,
                .fan_in => s.fan_in += 1,
                .gate => s.gates += 1,
                .verify => s.verify += 1,
                .approval => s.approval += 1,
                .work => {},
            }
        }
        return s;
    }

    pub fn toJson(self: *const Graph) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "skill", try ju.strVal(self.gpa, self.skill));
        try ju.putKey(self.gpa, &obj.object, "name", try ju.strVal(self.gpa, self.name));
        try ju.putKey(self.gpa, &obj.object, "input", try ju.copyJsonValue(self.gpa, self.input));
        var arr = ju.newArr(self.gpa);
        for (self.nodes.items) |n| try arr.array.append(try n.toJson(self.gpa));
        try ju.putKey(self.gpa, &obj.object, "nodes", arr);
        if (self.termination) |t| try ju.putKey(self.gpa, &obj.object, "termination", try t.toJson(self.gpa));
        return obj;
    }

    pub fn fromJson(gpa: Allocator, v: std.json.Value) !Graph {
        if (v != .object) return error.InvalidNode;
        const root = v.object;
        var graph = Graph.init(gpa, ju.objStr(root, "skill"), ju.objStr(root, "name"));
        errdefer graph.deinit();

        graph.input = try ju.copyJsonValue(gpa, root.get("input") orelse .null);

        if (ju.objGet(root, "termination")) |t_v| {
            if (t_v == .object) {
                const t = t_v.object;
                const kind = constraints.kindFromString(ju.objStr(t, "kind")) orelse return error.InvalidNode;
                const dir = constraints.directionFromString(ju.objStr(t, "direction")) orelse .min;
                try graph.setTermination(.{
                    .kind = kind,
                    .limit = numberFromValue(t.get("limit")),
                    .direction = dir,
                    .max_iterations = ju.objNum(t, "max_iterations"),
                    // setTermination 自己会复制 criterion：这里再 dupe 一次就是泄漏。
                    .criterion = ju.objStr(t, "criterion"),
                });
            }
        }

        if (ju.objGet(root, "nodes")) |n_v| {
            if (n_v == .array) {
                for (n_v.array.items) |item| {
                    if (item != .object) continue;
                    const o = item.object;
                    const kind = kindFromString(ju.objStr(o, "kind")) orelse .work;
                    const tier = tierFromString(ju.objStr(o, "tier")) orelse .standard;
                    const risk = riskFromString(ju.objStr(o, "risk")) orelse .low;

                    var deps: std.ArrayList([]const u8) = .empty;
                    defer deps.deinit(
                        gpa,
                    );
                    if (ju.objGet(o, "depends_on")) |d_v| {
                        if (d_v == .array) {
                            for (d_v.array.items) |d| {
                                if (d == .string) try deps.append(gpa, d.string);
                            }
                        }
                    }

                    try graph.add(.{
                        .id = ju.objStr(o, "id"),
                        .capability = ju.objStr(o, "capability"),
                        .kind = kind,
                        .tier = tier,
                        .risk = risk,
                        .skill = ju.objStr(o, "skill"),
                        .phase = ju.objNum(o, "phase"),
                        .depends_on = deps.items,
                        .payload = o.get("payload") orelse .null,
                        .writes = ju.objStr(o, "writes"),
                        .rederive = boolFromValue(o.get("rederive")),
                        .retry_target = ju.objStr(o, "retry_target"),
                        .batch = ju.objNum(o, "batch"),
                        .irreversible = boolFromValue(o.get("irreversible")),
                        .fresh_context = boolFromValue(o.get("fresh_context")),
                        .max_parallel = ju.objNum(o, "max_parallel"),
                    });
                }
            }
        }

        return graph;
    }
};

pub fn numberFromValue(v: ?std.json.Value) f64 {
    if (v) |x| {
        if (x == .float) return x.float;
        if (x == .integer) return @floatFromInt(x.integer);
    }
    return 0.0;
}

fn boolFromValue(v: ?std.json.Value) bool {
    if (v) |x| {
        if (x == .bool) return x.bool;
    }
    return false;
}

fn transitivelyDepends(graph: *const Graph, from: usize, to: usize, seen: *std.AutoHashMap(usize, bool)) !bool {
    if (from == to) return false;
    if (seen.get(to) != null) return false;
    try seen.put(to, true);
    const target = graph.nodeAt(to);
    for (target.depends_on) |d| {
        const di = graph.find(d) orelse continue;
        if (di == from) return true;
        if (try transitivelyDepends(graph, from, di, seen)) return true;
    }
    return false;
}

test "graph dependency audit separates narration from real edges" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "graph-orchestrator", "audit");
    defer g.deinit();

    try g.add(.{ .id = "rubric", .capability = "define_rubric", .kind = .work });
    try g.add(.{ .id = "batch_a", .capability = "audit", .kind = .fan_out, .tier = .standard, .depends_on = &.{"rubric"} });
    try g.add(.{ .id = "batch_b", .capability = "audit", .kind = .fan_out, .tier = .standard, .depends_on = &.{"rubric"} });
    try g.add(.{ .id = "merge", .capability = "consolidate", .kind = .fan_in, .tier = .cheap, .batch = 25, .depends_on = &.{ "batch_a", "batch_b" } });

    try g.validate();
    try std.testing.expect(try g.independent(g.find("batch_a").?, g.find("batch_b").?));
    try std.testing.expect(!(try g.independent(g.find("rubric").?, g.find("merge").?)));

    const layers = try g.layers();
    defer {
        for (layers) |l| gpa.free(l);
        gpa.free(layers);
    }
    try std.testing.expectEqual(@as(usize, 3), layers.len);
    try std.testing.expectEqual(@as(usize, 2), layers[1].len);
}

test "hidden edges from shared writes" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "graph-orchestrator", "shared write");
    defer g.deinit();

    try g.add(.{ .id = "a", .capability = "write", .writes = "bom" });
    try g.add(.{ .id = "b", .capability = "write", .writes = "bom" });
    try g.validate();

    try std.testing.expect(!(try g.independent(g.find("a").?, g.find("b").?)));

    const edges = try g.hiddenEdges();
    defer {
        for (edges) |e| gpa.free(e.reason);
        gpa.free(edges);
    }
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("shared write: bom", edges[0].reason);
}

test "cycle and unknown dependency are rejected" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "graph-orchestrator", "cycle");
    defer g.deinit();

    try g.add(.{ .id = "a", .capability = "x", .depends_on = &.{"b"} });
    try g.add(.{ .id = "b", .capability = "y", .depends_on = &.{"a"} });
    try std.testing.expectError(error.CycleDetected, g.layers());

    var g2 = Graph.init(gpa, "graph-orchestrator", "unknown");
    defer g2.deinit();
    try g2.add(.{ .id = "a", .capability = "x", .depends_on = &.{"ghost"} });
    try std.testing.expectError(error.UnknownDependency, g2.validate());
}

test "irreversible action needs an approval gate" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "graph-orchestrator", "order");
    defer g.deinit();

    try g.add(.{ .id = "verify", .capability = "rederive", .kind = .verify, .rederive = true });
    try g.add(.{ .id = "gate", .capability = "human_approval", .kind = .approval, .risk = .high, .depends_on = &.{"verify"} });
    try g.add(.{ .id = "send", .capability = "order", .risk = .irreversible, .irreversible = true, .depends_on = &.{"gate"} });
    try g.validate();

    const edges = try g.hiddenEdges();
    defer {
        for (edges) |e| gpa.free(e.reason);
        gpa.free(edges);
    }
    try std.testing.expect(edges.len >= 1);

    var g2 = Graph.init(gpa, "graph-orchestrator", "no gate");
    defer g2.deinit();
    try g2.add(.{ .id = "send", .capability = "order", .risk = .irreversible, .irreversible = true });
    try std.testing.expectError(error.IrreversibleNeedsApproval, g2.validate());
}

test "narration edges are separated from real edges" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "work-shape-audit", "Shape");
    defer g.deinit();

    // kickoff 不产出任何东西：指向它的箭头只是叙述上的先后。
    try g.add(.{ .id = "kickoff", .capability = "kickoff", .kind = .work });
    // 真正的数据依赖：上游写入 artifact，下游读它。
    try g.add(.{ .id = "audit", .capability = "audit", .kind = .work, .depends_on = &.{"kickoff"}, .writes = "findings" });
    try g.add(.{ .id = "draft", .capability = "draft", .kind = .work, .depends_on = &.{"audit"} });
    try g.add(.{ .id = "note", .capability = "note", .kind = .work, .depends_on = &.{"kickoff"} });

    const edges = try g.narrationEdges();
    defer gpa.free(edges);
    try std.testing.expectEqual(@as(usize, 2), edges.len);

    const shape = try g.shapeOfWork();
    defer shape.free(gpa);
    try std.testing.expectEqual(@as(usize, 6), shape.pairs);
    try std.testing.expectEqual(@as(usize, 3), shape.real_edges);
    try std.testing.expectEqual(@as(usize, 2), shape.narration_edges);
    // audit 与 note / draft 之间没有数据流：这一层可以 fan-out。
    try std.testing.expectEqual(@as(usize, 2), shape.independent_pairs);
    try std.testing.expectEqualStrings("partially splittable: fan out only the 2 independent pairs, keep the rest sequential", shape.recommendation);
}

test "sequential work is not forced into a graph" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "chain", "Chain");
    defer g.deinit();

    try g.add(.{ .id = "a", .capability = "read", .kind = .work, .writes = "a" });
    try g.add(.{ .id = "b", .capability = "transform", .kind = .work, .depends_on = &.{"a"}, .writes = "b" });
    try g.add(.{ .id = "c", .capability = "publish", .kind = .work, .depends_on = &.{"b"}, .writes = "c" });

    const shape = try g.shapeOfWork();
    defer shape.free(gpa);
    try std.testing.expectEqual(@as(usize, 0), shape.independent_pairs);
    try std.testing.expectEqual(@as(usize, 0), shape.narration_edges);
    try std.testing.expect(std.mem.indexOf(u8, shape.recommendation, "keep it a chain") != null);
}

test "graph json roundtrip keeps termination criterion" {
    const gpa = std.testing.allocator;
    var g = Graph.init(gpa, "pcb-design-review", "review");
    defer g.deinit();
    try g.setTermination(.{
        .kind = .drc_errors,
        .limit = 0,
        .direction = .max,
        .max_iterations = 4,
        .criterion = "hard DRC violations must be zero before the loop can stop",
    });
    try g.add(.{ .id = "parse", .capability = "read_kicad", .writes = "board" });

    const json = try g.toJson();
    defer ju.freeJsonValue(gpa, json);
    const text = try ju.stringifyAlloc(gpa, json);
    defer gpa.free(text);

    const parsed = try ju.parseValue(gpa, text);
    defer ju.freeJsonValue(gpa, parsed);
    var reloaded = try Graph.fromJson(gpa, parsed);
    defer reloaded.deinit();

    try std.testing.expectEqualStrings("pcb-design-review", reloaded.skill);
    try std.testing.expectEqual(@as(usize, 1), reloaded.count());
    try std.testing.expect(reloaded.termination != null);
    try std.testing.expect(reloaded.termination.?.satisfied(0));
    try std.testing.expect(!reloaded.termination.?.satisfied(1));
}
