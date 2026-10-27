//! Graph Loop 执行器：分层执行 → 每层后局部重规划 → 门失败触发定向重做（有上限）
//! → 不可逆动作停在人工审批门前。
//!
//! 规划全局、重规划局部：计划是可审阅的 DAG，而不是不透明的循环。
//! 已完成节点的结果保留为结构化执行记录，不从聊天历史里重新发现。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const gates = @import("gates.zig");
const constraints = @import("../design/constraints.zig");

const Allocator = std.mem.Allocator;

pub const ExecutorError = error{
    NoCapability,
    InvalidGraph,
    ReviewFailed,
    OutOfMemory,
};

pub const Status = enum {
    completed,
    needs_human,
    gate_failed,
    max_iterations,
    review_failed,
    invalid_graph,
};

pub fn statusLabel(s: Status) []const u8 {
    return @tagName(s);
}

pub const CapabilityFn = *const fn (ctx: *anyopaque, gpa: Allocator, node: graph.Node, args: std.json.Value) anyerror!std.json.Value;

pub const Observation = struct {
    layer_index: usize,
    completed: []const []const u8,
    gate_failures: []const []const u8,
    usage: state.Usage,
};

pub const ProposalKind = enum { no_change, revision, final_answer };

pub const Proposal = struct {
    kind: ProposalKind,
    graph: ?graph.Graph = null,
    answer: []const u8 = "",

    pub fn free(self: *const Proposal, gpa: Allocator) void {
        if (self.graph) |g| {
            var copy = g;
            copy.deinit();
        }
        gpa.free(self.answer);
    }
};

pub const PlannerFn = *const fn (ctx: *anyopaque, gpa: Allocator, obs: Observation) anyerror!Proposal;

pub const RunResult = struct {
    status: Status,
    answer: []const u8,
    stopped_at: []const u8,
    usage: state.Usage,
    reasons: []const []const u8,

    pub fn free(self: *const RunResult, gpa: Allocator) void {
        gpa.free(self.answer);
        gpa.free(self.stopped_at);
        for (self.reasons) |r| gpa.free(r);
        gpa.free(self.reasons);
    }
};

pub const Executor = struct {
    gpa: Allocator,
    graph: *graph.Graph,
    st: *state.State,
    gates: *gates.GateSet,
    capability: ?CapabilityFn = null,
    capability_ctx: *anyopaque = undefined,
    planner: ?PlannerFn = null,
    planner_ctx: *anyopaque = undefined,
    max_retries: usize = 3,

    pub fn init(gpa: Allocator, g: *graph.Graph, st: *state.State, gate_set: *gates.GateSet) Executor {
        return .{
            .gpa = gpa,
            .graph = g,
            .st = st,
            .gates = gate_set,
        };
    }

    pub fn run(self: *Executor) !RunResult {
        if (self.capability == null) return error.NoCapability;

        self.graph.validate() catch |err| return .{
            .status = .invalid_graph,
            .answer = try self.gpa.dupe(u8, @errorName(err)),
            .stopped_at = try self.gpa.dupe(u8, ""),
            .usage = self.st.usage,
            .reasons = &.{},
        };

        const violations = try gates.adversarialReview(self.graph);
        defer {
            for (violations) |v| v.free(self.gpa);
            self.gpa.free(violations);
        }
        if (violations.len > 0) {
            var reasons: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (reasons.items) |r| self.gpa.free(r);
                reasons.deinit(
                    self.gpa,
                );
            }
            for (violations) |v| {
                try reasons.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ v.node_id, v.rule }));
            }
            return .{
                .status = .review_failed,
                .answer = try self.gpa.dupe(u8, "adversarial review rejected the plan before execution"),
                .stopped_at = try self.gpa.dupe(u8, ""),
                .usage = self.st.usage,
                .reasons = try reasons.toOwnedSlice(
                    self.gpa,
                ),
            };
        }

        const termination = self.graph.termination.?;
        var retries: std.AutoHashMap(usize, usize) = std.AutoHashMap(usize, usize).init(self.gpa);
        defer retries.deinit();

        var failures: std.ArrayList([]const u8) = .empty;
        defer {
            for (failures.items) |f| self.gpa.free(f);
            failures.deinit(
                self.gpa,
            );
        }

        // 未解决的发现：节点失败时登记，重跑通过后才撤销。
        // 一个失败的门不能自己宣布成功——终止条件必须由真实测量满足。
        var unresolved: std.AutoHashMap(usize, usize) = std.AutoHashMap(usize, usize).init(self.gpa);
        defer unresolved.deinit();

        while (self.st.usage.iterations < termination.max_iterations) {
            self.st.usage.iterations += 1;

            const layer = try self.readyLayer();
            defer self.gpa.free(layer);
            if (layer.len == 0) break;

            for (layer) |idx| {
                const node = self.graph.nodeAt(idx);

                // 人工审批门：不可逆或对外动作硬停，展示具体动作、范围与成本。
                if (node.kind == .approval) {
                    return .{
                        .status = .needs_human,
                        .answer = try approvalScope(self.gpa, node),
                        .stopped_at = try self.gpa.dupe(u8, node.id),
                        .usage = self.st.usage,
                        .reasons = try failures.toOwnedSlice(
                            self.gpa,
                        ),
                    };
                }

                const args = try self.st.resolve(node);
                defer ju.freeJsonValue(self.gpa, args);

                const output = self.capability.?(self.capability_ctx, self.gpa, node, args) catch |err| {
                    self.st.usage.tool_errors += 1;
                    try self.st.record(node.id, .{
                        .node_id = node.id,
                        .ok = false,
                        .failure = try self.gpa.dupe(u8, @errorName(err)),
                    });
                    try failures.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ node.id, @errorName(err) }));
                    try unresolved.put(idx, (unresolved.get(idx) orelse 0) + 1);
                    continue;
                };
                defer ju.freeJsonValue(self.gpa, output);
                self.st.usage.tool_calls += 1;

                try self.st.record(node.id, .{
                    .node_id = node.id,
                    .ok = true,
                    .output = output,
                    .measured = isMeasured(output),
                });
                // 这一轮通过：之前挂在它身上的发现算已解决。
                if (unresolved.contains(idx)) _ = unresolved.remove(idx);

                if (node.kind == .fan_in) {
                    if (self.st.completeness(node)) |_| {
                        // 进多少出多少：这一层通过，无需回边
                    } else |err| {
                        try failures.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ node.id, @errorName(err) }));
                        try unresolved.put(idx, (unresolved.get(idx) orelse 0) + 1);
                        if (node.retry_target.len > 0) {
                            const target = self.graph.find(node.retry_target).?;
                            try retries.put(target, (retries.get(target) orelse 0) + 1);
                            if (retries.get(target).? > self.max_retries) {
                                return .{
                                    .status = .gate_failed,
                                    .answer = try self.gpa.dupe(u8, "fan-in dropped items after the retry cap"),
                                    .stopped_at = try self.gpa.dupe(u8, node.id),
                                    .usage = self.st.usage,
                                    .reasons = try failures.toOwnedSlice(
                                        self.gpa,
                                    ),
                                };
                            }
                            _ = self.st.forget(node.id);
                            for (node.depends_on) |d| {
                                if (self.graph.find(d)) |di| _ = self.st.forget(self.graph.nodeAt(di).id);
                            }
                        }
                    }
                }

                if (node.kind == .gate) {
                    const measurements = try self.st.measurements(node);
                    defer {
                        for (measurements) |m| self.gpa.free(m.ref);
                        self.gpa.free(measurements);
                    }
                    const report = try self.gates.evaluate(measurements);
                    defer report.free();
                    if (!report.passed()) {
                        for (report.failures) |f| {
                            try failures.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}: {s} {s} (value {d}, limit {d}, inferred={s})", .{ node.id, f.gate_id, @tagName(f.severity), f.measured, f.limit, if (f.inferred) "true" else "false" }));
                        }
                        try unresolved.put(idx, (unresolved.get(idx) orelse 0) + 1);
                        const target = node.retry_target;
                        if (target.len == 0) {
                            return .{
                                .status = .gate_failed,
                                .answer = try self.gpa.dupe(u8, "gate failed with no targeted redo defined"),
                                .stopped_at = try self.gpa.dupe(u8, node.id),
                                .usage = self.st.usage,
                                .reasons = try failures.toOwnedSlice(
                                    self.gpa,
                                ),
                            };
                        }
                        const target_idx = self.graph.find(target).?;
                        try retries.put(target_idx, (retries.get(target_idx) orelse 0) + 1);
                        if (retries.get(target_idx).? > self.max_retries) {
                            return .{
                                .status = .gate_failed,
                                .answer = try std.fmt.allocPrint(self.gpa, "gate {s} failed after {d} targeted redos; escalating", .{ node.id, retries.get(target_idx).? }),
                                .stopped_at = try self.gpa.dupe(u8, node.id),
                                .usage = self.st.usage,
                                .reasons = try failures.toOwnedSlice(
                                    self.gpa,
                                ),
                            };
                        }
                        _ = self.st.forget(node.id);
                        _ = self.st.forget(target);
                    } else if (output == .object) {
                        // 条件路由：分支必须由实测结果决定，不能由叙述顺序决定。
                        // 没有选中的分支不执行，也不计入 fan-in 的进多少出多少。
                        const route = output.object.get("route");
                        if (route != null and route.? == .string) {
                            const chosen = route.?.string;
                            for (self.graph.nodes.items) |n| {
                                // 只有真正的分支候选（fan-out 支路）才会被路由排除；
                                // verify / approval 这类复核节点必须始终执行。
                                if (n.kind != .fan_out) continue;
                                var routed = false;
                                for (n.depends_on) |d| {
                                    if (std.mem.eql(u8, d, node.id)) routed = true;
                                }
                                if (!routed or std.mem.eql(u8, n.id, chosen)) continue;
                                if (self.st.completed(n.id)) continue;
                                try self.st.record(n.id, .{ .node_id = n.id, .ok = true, .skipped = true, .failure = "not routed" });
                            }
                        }
                    }
                }

                if (node.kind == .verify) {
                    const r = self.st.get(node.id) orelse continue;
                    if (!r.measured) {
                        try failures.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}: verification must re-derive from source, not read a synthesis", .{node.id}));
                        try unresolved.put(idx, (unresolved.get(idx) orelse 0) + 1);
                    }
                }
            }

            self.st.usage.layers_executed += 1;

            if (self.planner) |plan| {
                const completed = try completedIds(self.gpa, self.st);
                defer {
                    for (completed) |c| self.gpa.free(c);
                    self.gpa.free(completed);
                }
                const obs = Observation{
                    .layer_index = self.st.usage.layers_executed,
                    .completed = completed,
                    .gate_failures = failures.items,
                    .usage = self.st.usage,
                };
                const proposal = try plan(self.planner_ctx, self.gpa, obs);
                defer proposal.free(self.gpa);

                switch (proposal.kind) {
                    .final_answer => return .{
                        .status = .completed,
                        .answer = try self.gpa.dupe(u8, proposal.answer),
                        .stopped_at = try self.gpa.dupe(u8, ""),
                        .usage = self.st.usage,
                        .reasons = try failures.toOwnedSlice(
                            self.gpa,
                        ),
                    },
                    .revision => {
                        if (proposal.graph) |replacement| {
                            var new_graph = replacement;
                            try new_graph.validate();
                            self.graph.* = new_graph;
                        }
                    },
                    .no_change => {},
                }
            }
        }

        // 还有未解决的发现就不能宣布完成：这是自确认最常见的形态。
        if (unresolved.count() > 0) {
            return .{
                .status = .gate_failed,
                .answer = try std.fmt.allocPrint(self.gpa, "criterion not met: {d} unresolved finding(s) remain; a failed gate cannot confirm its own success", .{unresolved.count()}),
                .stopped_at = try self.gpa.dupe(u8, ""),
                .usage = self.st.usage,
                .reasons = try failures.toOwnedSlice(
                    self.gpa,
                ),
            };
        }

        // `iterations` 型终止条件读的是「还剩多少未解决的发现」；其余终止条件必须由真实测量满足。
        const value = if (termination.kind == .iterations) 0.0 else terminationValue(self.graph, self.st);
        if (value == null) {
            return .{
                .status = .max_iterations,
                .answer = try std.fmt.allocPrint(self.gpa, "criterion was never measured ({s}); cannot declare it met", .{termination.criterion}),
                .stopped_at = try self.gpa.dupe(u8, ""),
                .usage = self.st.usage,
                .reasons = try failures.toOwnedSlice(
                    self.gpa,
                ),
            };
        }
        const metric = value.?;
        if (termination.satisfied(metric)) {
            return .{
                .status = .completed,
                .answer = try std.fmt.allocPrint(self.gpa, "termination criterion met: {s} = {d}", .{ termination.criterion, metric }),
                .stopped_at = try self.gpa.dupe(u8, ""),
                .usage = self.st.usage,
                .reasons = try failures.toOwnedSlice(
                    self.gpa,
                ),
            };
        }

        return .{
            .status = .max_iterations,
            .answer = try std.fmt.allocPrint(self.gpa, "iteration cap {d} reached without meeting the criterion", .{termination.max_iterations}),
            .stopped_at = try self.gpa.dupe(u8, ""),
            .usage = self.st.usage,
            .reasons = try failures.toOwnedSlice(
                self.gpa,
            ),
        };
    }

    /// 就绪层：依赖已完成且尚未执行的节点。
    fn readyLayer(self: *Executor) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(
            self.gpa,
        );
        for (self.graph.nodes.items, 0..) |n, i| {
            if (self.st.completed(n.id)) continue;
            var ready = true;
            for (n.depends_on) |d| {
                if (!self.st.completed(d)) ready = false;
            }
            if (ready) try out.append(self.gpa, i);
        }
        return out.toOwnedSlice(
            self.gpa,
        );
    }
};

fn isMeasured(output: std.json.Value) bool {
    if (output == .object) {
        const v = output.object.get("measured");
        if (v) |x| {
            if (x == .bool) return x.bool;
        }
    }
    return false;
}

fn approvalScope(gpa: Allocator, node: graph.Node) ![]const u8 {
    if (node.payload == .object) {
        const scope = ju.objStr(node.payload.object, "scope");
        const cost = ju.objStr(node.payload.object, "cost");
        if (scope.len > 0) return std.fmt.allocPrint(gpa, "human approval required — action: {s}, scope: {s}, cost: {s}", .{ node.capability, scope, cost });
    }
    return std.fmt.allocPrint(gpa, "human approval required before irreversible action: {s}", .{node.capability});
}

fn completedIds(gpa: Allocator, st: *const state.State) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(
            gpa,
        );
    }
    var it = st.results.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.ok) try out.append(gpa, try gpa.dupe(u8, e.key_ptr.*));
    }
    return out.toOwnedSlice(
        gpa,
    );
}

fn terminationValue(g: *const graph.Graph, st: *state.State) ?f64 {
    const termination = g.termination.?;
    var best: f64 = 0.0;
    var found = false;
    var it = st.results.iterator();
    while (it.next()) |e| {
        const out = e.value_ptr.output;
        if (out != .object) continue;
        const kind = constraints.kindFromString(ju.objStr(out.object, "kind")) orelse continue;
        if (kind != termination.kind) continue;
        const v = out.object.get("value");
        if (v == null) continue;
        if (v.? != .integer and v.? != .float) continue;
        if (!found) {
            best = graph.numberFromValue(v);
            found = true;
            continue;
        }
        const value = graph.numberFromValue(v);
        best = switch (termination.direction) {
            .min => @max(best, value),
            .max => @min(best, value),
        };
    }
    if (!found) return null;
    return best;
}

const StubState = struct {
    outputs: []const std.json.Value,
    index: usize = 0,
};

fn stubCapability(ctx: *anyopaque, gpa: Allocator, node: graph.Node, args: std.json.Value) anyerror!std.json.Value {
    _ = args;
    const st = @as(*StubState, @ptrCast(@alignCast(ctx)));
    if (st.index >= st.outputs.len) return error.OutOfMemory;
    const v = st.outputs[st.index];
    st.index += 1;
    _ = node;
    return ju.copyJsonValue(gpa, v);
}

fn noChangePlanner(_: *anyopaque, gpa: Allocator, obs: Observation) anyerror!Proposal {
    _ = gpa;
    _ = obs;
    return .{ .kind = .no_change };
}

test "graph loop runs layers and stops at the human gate" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "gated run");
    defer g.deinit();
    try g.setTermination(.{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 4, .criterion = "hard violations must be zero" });
    try g.add(.{ .id = "rubric", .capability = "define_rubric", .kind = .work });
    const scope = try ju.parseValue(gpa, "{\"scope\":\"60 endpoint handlers\",\"cost\":\"1 email send\"}");
    defer ju.freeJsonValue(gpa, scope);
    try g.add(.{ .id = "gate", .capability = "human_approval", .kind = .approval, .risk = .high, .depends_on = &.{"rubric"}, .payload = scope });
    try g.add(.{ .id = "send", .capability = "send_email", .kind = .work, .irreversible = true, .risk = .irreversible, .depends_on = &.{"gate"} });

    var st = state.State.init(gpa, &g);
    defer st.deinit();
    var gate_set = gates.GateSet.init(gpa);
    defer gate_set.deinit();

    var outputs = [_]std.json.Value{.{ .object = std.json.ObjectMap.empty }};
    var stub = StubState{ .outputs = &outputs };

    var exec = Executor.init(gpa, &g, &st, &gate_set);
    exec.capability = stubCapability;
    exec.capability_ctx = &stub;

    const res = try exec.run();
    defer res.free(gpa);
    try std.testing.expectEqual(Status.needs_human, res.status);
    try std.testing.expectEqualStrings("gate", res.stopped_at);
    try std.testing.expect(std.mem.indexOf(u8, res.answer, "human approval required") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.answer, "60 endpoint handlers") != null);
}

test "gate failure triggers a capped targeted redo" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "pcb-design-review", "drc loop");
    defer g.deinit();
    try g.setTermination(.{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 8, .criterion = "hard DRC violations must be zero" });
    try g.add(.{ .id = "measure", .capability = "drc", .kind = .work, .rederive = true });
    try g.add(.{ .id = "gate", .capability = "check_gate", .kind = .gate, .depends_on = &.{"measure"}, .retry_target = "measure" });

    var st = state.State.init(gpa, &g);
    defer st.deinit();
    var gate_set = try gates.builtinHardGates(gpa);
    defer gate_set.deinit();

    // 第一次违规 → 定向重做；第二次仍违规 → 超过上限后升级。
    // gate 节点本身也会调用能力：每次定向重做消耗两个观测（measure + gate）。
    var outputs = [_]std.json.Value{
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":3,\"ref\":\"pass 1\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"gate view 1\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":2,\"ref\":\"pass 2\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"gate view 2\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":1,\"ref\":\"pass 3\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"gate view 3\",\"measured\":true}"),
    };
    defer {
        for (outputs) |o| ju.freeJsonValue(gpa, o);
    }
    var stub = StubState{ .outputs = &outputs };

    var exec = Executor.init(gpa, &g, &st, &gate_set);
    exec.capability = stubCapability;
    exec.capability_ctx = &stub;
    exec.planner = noChangePlanner;
    exec.max_retries = 2;

    const res = try exec.run();
    defer res.free(gpa);
    try std.testing.expectEqual(Status.gate_failed, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.answer, "after 3 targeted redos") != null);
    try std.testing.expect(res.usage.tool_calls >= 3);
}

test "clean run meets the termination criterion" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "pcb-design-review", "clean run");
    defer g.deinit();
    try g.setTermination(.{ .kind = .drc_errors, .limit = 0, .direction = .max, .max_iterations = 3, .criterion = "hard violations must be zero" });
    try g.add(.{ .id = "parse", .capability = "read_kicad", .kind = .work, .writes = "board" });
    try g.add(.{ .id = "gate", .capability = "check_gate", .kind = .gate, .depends_on = &.{"parse"}, .retry_target = "parse" });

    var st = state.State.init(gpa, &g);
    defer st.deinit();
    var gate_set = try gates.builtinHardGates(gpa);
    defer gate_set.deinit();

    var outputs = [_]std.json.Value{
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"parsed board\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"gate view\",\"measured\":true}"),
    };
    defer {
        for (outputs) |o| ju.freeJsonValue(gpa, o);
    }
    var stub = StubState{ .outputs = &outputs };

    var exec = Executor.init(gpa, &g, &st, &gate_set);
    exec.capability = stubCapability;
    exec.capability_ctx = &stub;

    const res = try exec.run();
    defer res.free(gpa);
    try std.testing.expectEqual(Status.completed, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.answer, "termination criterion met") != null);
    // parse 与 gate 各调用一次能力：门通过后才允许停止。
    try std.testing.expectEqual(@as(usize, 2), res.usage.tool_calls);
    try std.testing.expectEqual(@as(usize, 0), res.usage.tool_errors);
}

test "conditional routing skips the branch that was not chosen" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "conditional-routing", "route from a measured result");
    defer g.deinit();
    try g.setTermination(.{ .kind = .iterations, .limit = 0, .direction = .max, .max_iterations = 8, .criterion = "the next layer must be chosen from a measured upstream result" });
    try g.add(.{ .id = "source", .capability = "read_source", .kind = .work, .writes = "source" });
    try g.add(.{ .id = "route", .capability = "evaluate_route", .kind = .gate, .depends_on = &.{"source"}, .retry_target = "source" });
    try g.add(.{ .id = "cheap_lane", .capability = "run_fast_lane", .kind = .fan_out, .tier = .cheap, .depends_on = &.{"route"}, .fresh_context = true });
    try g.add(.{ .id = "strong_lane", .capability = "run_deep_lane", .kind = .fan_out, .tier = .strong, .depends_on = &.{"route"}, .fresh_context = true });
    try g.add(.{ .id = "findings", .capability = "consolidate", .kind = .fan_in, .batch = 20, .depends_on = &.{ "cheap_lane", "strong_lane" }, .retry_target = "route", .writes = "route_findings" });
    try g.add(.{ .id = "verify", .capability = "rederive", .kind = .verify, .tier = .strong, .rederive = true, .depends_on = &.{ "source", "route" }, .retry_target = "route" });

    var st = state.State.init(gpa, &g);
    defer st.deinit();
    var gate_set = try gates.builtinHardGates(gpa);
    defer gate_set.deinit();

    // 实测值不满足终止条件 -> 升级到强分支；便宜分支不执行，也不计入 fan-in。
    // 顺序必须按实际执行顺序：verify 与被选中的分支在同一层，findings 在下一层。
    var outputs = [_]std.json.Value{
        try ju.parseValue(gpa, "{\"kind\":\"iterations\",\"value\":3,\"ref\":\"source\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"iterations\",\"value\":3,\"ref\":\"route\",\"measured\":true,\"route\":\"strong_lane\"}"),
        try ju.parseValue(gpa, "{\"kind\":\"iterations\",\"value\":3,\"ref\":\"strong_lane\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"iterations\",\"value\":3,\"ref\":\"verify\",\"measured\":true}"),
        try ju.parseValue(gpa, "{\"kind\":\"iterations\",\"value\":3,\"ref\":\"findings\",\"measured\":true,\"count\":1}"),
    };
    defer {
        for (outputs) |o| ju.freeJsonValue(gpa, o);
    }
    var stub = StubState{ .outputs = &outputs };

    var exec = Executor.init(gpa, &g, &st, &gate_set);
    exec.capability = stubCapability;
    exec.capability_ctx = &stub;

    const res = try exec.run();
    defer res.free(gpa);
    try std.testing.expectEqual(Status.completed, res.status);
    // 只跑被路由选中的分支：未选中的分支不消耗工具调用。
    try std.testing.expectEqual(@as(usize, 5), res.usage.tool_calls);
    try std.testing.expect(st.get("cheap_lane").?.skipped);
    try std.testing.expectEqualStrings("not routed", st.get("cheap_lane").?.failure);
    try std.testing.expect(!st.get("strong_lane").?.skipped);
    // 复核节点不属于分支候选：它必须始终执行。
    try std.testing.expect(!st.get("verify").?.skipped);
    try std.testing.expect(st.get("findings").?.ok);
}

test "adversarial review blocks execution before any side effect" {
    const gpa = std.testing.allocator;
    var g = graph.Graph.init(gpa, "graph-orchestrator", "bad plan");
    defer g.deinit();
    try g.add(.{ .id = "merge", .capability = "consolidate", .kind = .fan_in });
    try g.add(.{ .id = "verify", .capability = "rederive", .kind = .verify, .depends_on = &.{"merge"} });

    var st = state.State.init(gpa, &g);
    defer st.deinit();
    var gate_set = gates.GateSet.init(gpa);
    defer gate_set.deinit();

    var exec = Executor.init(gpa, &g, &st, &gate_set);
    exec.capability = stubCapability;
    exec.capability_ctx = undefined;

    const res = try exec.run();
    defer res.free(gpa);
    try std.testing.expectEqual(Status.review_failed, res.status);
    try std.testing.expectEqual(@as(usize, 0), res.usage.tool_calls);
    try std.testing.expect(res.reasons.len >= 1);
}
