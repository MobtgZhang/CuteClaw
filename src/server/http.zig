//! HTTP 应用层：路由、会话、SSE 流式与 RPC 共享同一状态。
//! `handle` 不依赖 socket（纯函数），便于测试；serve 层只负责收发与写回。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("../core/jsonutil.zig");
const llm = @import("../core/llm.zig");
const tools = @import("../core/tools.zig");
const session = @import("../core/session.zig");
const agent = @import("../core/agent.zig");
const events = @import("../core/events.zig");
const sandbox = @import("../sandbox/policy.zig");
const kernel = @import("../plugins/kernel.zig");
const metrics = @import("../metrics.zig");
const claw = @import("../claw.zig");
const memory = @import("../memory.zig");
const version = @import("../version.zig");
const pcb = @import("../design/pcb.zig");
const validation = @import("../design/validation.zig");
const project = @import("../design/project.zig");
const kicad = @import("../adapters/kicad.zig");

pub const json_content_type = "application/json; charset=utf-8";
pub const sse_content_type = "text/event-stream; charset=utf-8";

pub const default_system_prompt = "你是 CuteClaw Design Agent，专注于 PCB 与产品外壳（CAD）设计：理解约束、调用设计工具、给出可验证的结论。";

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = json_content_type,
    body: []const u8 = "",

    pub fn free(self: *const Response, gpa: Allocator) void {
        gpa.free(self.body);
    }
};

/// SSE 写出器：`event: <kind>\ndata: <json>\n\n`。
pub const Sse = struct {
    gpa: Allocator,
    w: *std.Io.Writer,

    pub fn init(gpa: Allocator, w: *std.Io.Writer) Sse {
        return .{ .gpa = gpa, .w = w };
    }

    pub fn event(self: *Sse, kind: []const u8, data: std.json.Value) !void {
        const text = try ju.stringifyAlloc(self.gpa, data);
        defer self.gpa.free(text);
        try self.w.writeAll("event: ");
        try self.w.writeAll(kind);
        try self.w.writeAll("\ndata: ");
        try self.w.writeAll(text);
        try self.w.writeAll("\n\n");
        try self.w.flush();
    }
};

pub const Deps = struct {
    policy: *sandbox.Policy,
    registry: *tools.Registry,
    bus: *events.EventBus,
    plugins: *kernel.Kernel,
    client: *llm.Client,
    runtime: ?*claw.ClawRuntime = null,
    metrics: ?*metrics.MetricsRegistry = null,
    system_prompt: []const u8 = default_system_prompt,
};

pub const Responder = agent.Responder;
pub const StreamResponder = *const fn (ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef, sink: llm.StreamSink) anyerror!llm.Completion;

pub const App = struct {
    gpa: Allocator,
    policy: *sandbox.Policy,
    registry: *tools.Registry,
    bus: *events.EventBus,
    plugins: *kernel.Kernel,
    runtime: ?*claw.ClawRuntime,
    metrics: ?*metrics.MetricsRegistry,
    client: *llm.Client,
    sessions: std.StringHashMap(session.Session),
    system_prompt: []const u8,
    tool_ctx: tools.ToolCtx,
    max_rounds: usize = 12,
    responder: ?Responder = null,
    responder_ctx: ?*anyopaque = null,
    stream_responder: ?StreamResponder = null,
    stream_responder_ctx: ?*anyopaque = null,

    pub fn init(gpa: Allocator, deps: Deps) App {
        return .{
            .gpa = gpa,
            .policy = deps.policy,
            .registry = deps.registry,
            .bus = deps.bus,
            .plugins = deps.plugins,
            .runtime = deps.runtime,
            .metrics = deps.metrics,
            .client = deps.client,
            .sessions = std.StringHashMap(session.Session).init(gpa),
            .system_prompt = deps.system_prompt,
            .tool_ctx = .{ .gpa = gpa, .policy = deps.policy, .bus = deps.bus },
        };
    }

    pub fn deinit(self: *App) void {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.sessions.deinit();
    }

    pub fn ensureSession(self: *App, id: []const u8) !*session.Session {
        const entry = try self.sessions.getOrPut(id);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.gpa.dupe(u8, id);
            entry.value_ptr.* = session.Session.init(self.gpa, entry.key_ptr.*, self.client.config.model, self.system_prompt);
        }
        return entry.value_ptr;
    }

    /// 一轮对话：走 agent 主循环（LLM → 工具 → 回写）。
    pub fn chat(self: *App, id: []const u8, text: []const u8) !std.json.Value {
        const gpa = self.gpa;
        const sess = try self.ensureSession(id);
        var a = agent.Agent.init(gpa, sess, self.registry, &self.tool_ctx);
        a.bus = self.bus;
        a.max_rounds = self.max_rounds;
        if (self.responder) |r| a.responder = r;
        a.responder_ctx = self.responder_ctx orelse @as(*anyopaque, @ptrCast(self.client));

        const res = try a.runTurn(text);
        defer gpa.free(res.content);

        var obj = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, obj);
        try ju.putKey(gpa, &obj.object, "session", try ju.strVal(gpa, sess.id));
        try ju.putKey(gpa, &obj.object, "reply", try ju.strVal(gpa, res.content));
        try ju.putKey(gpa, &obj.object, "rounds", .{ .integer = @intCast(res.rounds) });
        try ju.putKey(gpa, &obj.object, "tool_calls", .{ .integer = @intCast(res.tool_calls) });
        try ju.putKey(gpa, &obj.object, "outcome", try ju.strVal(gpa, memory.outcomeTag(res.outcome)));
        return obj;
    }

    /// 流式对话：逐事件写出 delta / tool / done。
    pub fn chatStream(self: *App, id: []const u8, text: []const u8, sse: *Sse) !void {
        const gpa = self.gpa;
        const sess = try self.ensureSession(id);
        try sess.append(.{ .role = .user, .content = text });

        // 用 defer 而不是 errdefer：errdefer 会在后续轮次出错时二次释放同一份 JSON。
        const start = try sess.toJson();
        defer ju.freeJsonValue(gpa, start);
        try sse.event("session", start);

        var rounds: usize = 0;
        while (rounds < self.max_rounds) {
            rounds += 1;
            const prompt = try sess.prompt();
            defer session.Session.freePrompt(gpa, prompt);
            const defs = try self.registry.toolDefs();
            defer gpa.free(defs);

            var sink_ctx = StreamCtx{ .app = self, .sse = sse };
            const sink = llm.StreamSink{ .ctx = &sink_ctx, .emit = sseEmit };
            const completion = try self.runStream(sink, prompt, defs);
            defer llm.freeCompletion(gpa, completion);
            if (sink_ctx.failed) |e| return e;

            try sess.append(.{
                .role = .assistant,
                .content = completion.content,
                .reasoning = completion.reasoning,
                .tool_calls = completion.tool_calls,
            });

            if (completion.tool_calls.len == 0) {
                const done = try buildDone(gpa, completion, rounds);
                errdefer ju.freeJsonValue(gpa, done);
                try sse.event("done", done);
                ju.freeJsonValue(gpa, done);
                return;
            }

            for (completion.tool_calls) |tc| {
                const args = try ju.parseValue(gpa, tc.arguments);
                defer ju.freeJsonValue(gpa, args);

                const res = self.registry.execute(&self.tool_ctx, tc.name, args) catch |err| {
                    const msg = try std.fmt.allocPrint(gpa, "tool {s} failed: {s}", .{ tc.name, @errorName(err) });
                    defer gpa.free(msg);
                    try sess.append(.{ .role = .tool, .content = msg, .tool_call_id = tc.id });
                    const ev = try buildToolEvent(gpa, tc.name, false, msg);
                    defer ju.freeJsonValue(gpa, ev);
                    try sse.event("tool", ev);
                    continue;
                };
                defer res.free(gpa);
                try sess.append(.{ .role = .tool, .content = res.content, .tool_call_id = tc.id });
                const ev = try buildToolEvent(gpa, tc.name, res.ok, res.content);
                defer ju.freeJsonValue(gpa, ev);
                try sse.event("tool", ev);
            }
        }
    }

    fn runStream(self: *App, sink: llm.StreamSink, messages: []const llm.Message, defs: []const llm.ToolDef) !llm.Completion {
        if (self.stream_responder) |r| {
            const ctx = self.stream_responder_ctx orelse @as(*anyopaque, @ptrCast(self.client));
            return r(ctx, self.gpa, messages, defs, sink);
        }
        return self.client.completeStream(messages, defs, sink);
    }

    // --- 路由 ---

    pub fn handle(self: *App, method: []const u8, raw_path: []const u8, body: []const u8) !Response {
        const gpa = self.gpa;
        const route = pathWithoutQuery(raw_path);

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, route, "/api/health")) return jsonResponse(gpa, 200, try self.healthJson());
            if (std.mem.eql(u8, route, "/api/sessions")) return jsonResponse(gpa, 200, try self.sessionsJson());
            if (std.mem.eql(u8, route, "/api/tools")) return jsonResponse(gpa, 200, try self.toolsJson());
            if (std.mem.eql(u8, route, "/api/plugins")) return jsonResponse(gpa, 200, try self.pluginsJson());
            if (std.mem.eql(u8, route, "/api/metrics")) return jsonResponse(gpa, 200, try self.metricsJson());
            return errorResponse(gpa, 404, "not found");
        }

        if (std.mem.eql(u8, method, "POST")) {
            const req = try ju.parseValue(gpa, body);
            defer ju.freeJsonValue(gpa, req);
            if (req != .object) return errorResponse(gpa, 400, "body must be a JSON object");

            if (std.mem.eql(u8, route, "/api/chat")) {
                const id = ju.objStr(req.object, "session");
                const text = ju.objStr(req.object, "message");
                if (id.len == 0 or text.len == 0) return errorResponse(gpa, 400, "session and message are required");
                return jsonResponse(gpa, 200, try self.chat(id, text));
            }
            if (std.mem.eql(u8, route, "/api/drc")) {
                const proj = req.object.get("project") orelse req;
                if (proj != .object) return errorResponse(gpa, 400, "project must be a JSON object");
                return jsonResponse(gpa, 200, try self.drcJson(proj));
            }
            if (std.mem.eql(u8, route, "/api/kicad")) {
                const text = ju.objStr(req.object, "text");
                if (text.len == 0) return errorResponse(gpa, 400, "text is required");
                return jsonResponse(gpa, 200, try self.kicadJson(text));
            }
            return errorResponse(gpa, 404, "not found");
        }

        return errorResponse(gpa, 405, "method not allowed");
    }

    // --- 路由实现（RPC 复用）---

    pub fn healthJson(self: *App) !std.json.Value {
        const gpa = self.gpa;
        var obj = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, obj);
        try ju.putKey(gpa, &obj.object, "status", try ju.strVal(gpa, "ok"));
        try ju.putKey(gpa, &obj.object, "version", try ju.strVal(gpa, version.semantic));
        try ju.putKey(gpa, &obj.object, "model", try ju.strVal(gpa, self.client.config.model));
        try ju.putKey(gpa, &obj.object, "sessions", .{ .integer = @intCast(self.sessions.count()) });
        try ju.putKey(gpa, &obj.object, "tools", .{ .integer = @intCast(self.registry.count()) });
        try ju.putKey(gpa, &obj.object, "plugins", .{ .integer = @intCast(self.plugins.enabledCount()) });
        return obj;
    }

    pub fn sessionsJson(self: *App) !std.json.Value {
        const gpa = self.gpa;
        var arr = ju.newArr(gpa);
        errdefer ju.freeJsonValue(gpa, arr);
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            var sess = e.value_ptr;
            try arr.array.append(try sess.toJson());
        }
        return arr;
    }

    pub fn toolsJson(self: *App) !std.json.Value {
        const gpa = self.gpa;
        const defs = try self.registry.toolDefs();
        defer gpa.free(defs);
        var arr = ju.newArr(gpa);
        errdefer ju.freeJsonValue(gpa, arr);
        for (defs) |d| {
            var item = ju.newObj(gpa);
            errdefer ju.freeJsonValue(gpa, item);
            try ju.putKey(gpa, &item.object, "name", try ju.strVal(gpa, d.name));
            try ju.putKey(gpa, &item.object, "description", try ju.strVal(gpa, d.description));
            try ju.putKey(gpa, &item.object, "parameters", try ju.copyJsonValue(gpa, d.parameters));
            try arr.array.append(item);
        }
        return arr;
    }

    pub fn pluginsJson(self: *App) !std.json.Value {
        const gpa = self.gpa;
        var arr = ju.newArr(gpa);
        errdefer ju.freeJsonValue(gpa, arr);
        for (self.plugins.plugins.items) |p| {
            var item = ju.newObj(gpa);
            errdefer ju.freeJsonValue(gpa, item);
            try ju.putKey(gpa, &item.object, "id", try ju.strVal(gpa, p.id));
            try ju.putKey(gpa, &item.object, "version", try ju.strVal(gpa, p.manifest.version));
            try ju.putKey(gpa, &item.object, "bundle", try ju.strVal(gpa, p.manifest.bundle));
            try ju.putKey(gpa, &item.object, "enabled", .{ .bool = p.enabled });
            try ju.putKey(gpa, &item.object, "external", .{ .bool = p.manifest.external });
            try ju.putKey(gpa, &item.object, "capabilities", try strArray(gpa, p.manifest.capabilities));
            try arr.array.append(item);
        }
        return arr;
    }

    pub fn metricsJson(self: *App) !std.json.Value {
        const gpa = self.gpa;
        var obj = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, obj);
        var arr = ju.newArr(gpa);
        errdefer ju.freeJsonValue(gpa, arr);
        if (self.metrics) |reg| {
            var list: std.ArrayList(metrics.SkillRollup) = .empty;
            defer list.deinit(gpa);
            try reg.rollupSnapshot(gpa, &list);
            for (list.items) |r| {
                var item = ju.newObj(gpa);
                errdefer ju.freeJsonValue(gpa, item);
                try ju.putKey(gpa, &item.object, "skill", try ju.strVal(gpa, r.skill_name));
                try ju.putKey(gpa, &item.object, "invocations", .{ .integer = r.invocations });
                try ju.putKey(gpa, &item.object, "successes", .{ .integer = r.successes });
                try ju.putKey(gpa, &item.object, "failures", .{ .integer = r.failures });
                try ju.putKey(gpa, &item.object, "success_rate", .{ .float = metrics.successRate(r) });
                try arr.array.append(item);
            }
        }
        try ju.putKey(gpa, &obj.object, "skills", arr);
        return obj;
    }

    pub fn drcJson(self: *App, project_value: std.json.Value) !std.json.Value {
        const gpa = self.gpa;
        const text = try ju.stringifyAlloc(gpa, project_value);
        defer gpa.free(text);
        var p = try project.DesignProject.fromJson(gpa, text);
        defer p.deinit();
        const report = try validation.runDrc(gpa, &p.board, &p.constraints);
        defer report.free();
        return report.toJson();
    }

    pub fn kicadJson(self: *App, text: []const u8) !std.json.Value {
        const gpa = self.gpa;
        const root = try kicad.parse(gpa, text);
        defer kicad.free(gpa, root);
        var board = try kicad.readBoard(gpa, text);
        defer board.deinit();
        return boardJson(gpa, &board);
    }

    pub fn callTool(self: *App, name: []const u8, args: std.json.Value) !std.json.Value {
        const gpa = self.gpa;
        const res = try self.registry.execute(&self.tool_ctx, name, args);
        defer res.free(gpa);
        var obj = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, obj);
        try ju.putKey(gpa, &obj.object, "tool", try ju.strVal(gpa, name));
        try ju.putKey(gpa, &obj.object, "ok", .{ .bool = res.ok });
        try ju.putKey(gpa, &obj.object, "content", try ju.strVal(gpa, res.content));
        return obj;
    }
};

const StreamCtx = struct {
    app: *App,
    sse: *Sse,
    failed: ?anyerror = null,
};

fn streamEventTag(ev: llm.StreamEvent) []const u8 {
    return switch (ev) {
        .delta => "delta",
        .reasoning => "reasoning",
        .tool_call => "tool_call",
        .done => "assistant",
    };
}

fn buildStreamData(gpa: Allocator, ev: llm.StreamEvent) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    switch (ev) {
        .delta => |s| try ju.putKey(gpa, &obj.object, "text", try ju.strVal(gpa, s)),
        .reasoning => |s| try ju.putKey(gpa, &obj.object, "text", try ju.strVal(gpa, s)),
        .tool_call => |tc| {
            try ju.putKey(gpa, &obj.object, "id", try ju.strVal(gpa, tc.id));
            try ju.putKey(gpa, &obj.object, "name", try ju.strVal(gpa, tc.name));
            try ju.putKey(gpa, &obj.object, "arguments", try ju.strVal(gpa, tc.arguments));
        },
        .done => |c| {
            try ju.putKey(gpa, &obj.object, "text", try ju.strVal(gpa, c.content));
            try ju.putKey(gpa, &obj.object, "finish_reason", try ju.strVal(gpa, @tagName(c.finish_reason)));
        },
    }
    return obj;
}

/// `StreamSink.emit` 不能返回错误：失败记录到 ctx，由调用方在流结束后处理。
fn sseEmit(ctx: *anyopaque, ev: llm.StreamEvent) void {
    const c = @as(*StreamCtx, @ptrCast(@alignCast(ctx)));
    const gpa = c.app.gpa;
    const data = buildStreamData(gpa, ev) catch {
        c.failed = error.OutOfMemory;
        return;
    };
    c.sse.event(streamEventTag(ev), data) catch |e| {
        c.failed = e;
        ju.freeJsonValue(gpa, data);
        return;
    };
    ju.freeJsonValue(gpa, data);
}

fn buildDone(gpa: Allocator, completion: llm.Completion, rounds: usize) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "text", try ju.strVal(gpa, completion.content));
    try ju.putKey(gpa, &obj.object, "rounds", .{ .integer = @intCast(rounds) });
    try ju.putKey(gpa, &obj.object, "finish_reason", try ju.strVal(gpa, @tagName(completion.finish_reason)));
    try ju.putKey(gpa, &obj.object, "prompt_tokens", .{ .integer = @as(i64, @intCast(completion.usage.prompt_tokens)) });
    try ju.putKey(gpa, &obj.object, "completion_tokens", .{ .integer = @as(i64, @intCast(completion.usage.completion_tokens)) });
    return obj;
}

fn buildToolEvent(gpa: Allocator, name: []const u8, ok: bool, content: []const u8) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "tool", try ju.strVal(gpa, name));
    try ju.putKey(gpa, &obj.object, "ok", .{ .bool = ok });
    try ju.putKey(gpa, &obj.object, "content", try ju.strVal(gpa, content));
    return obj;
}

pub fn boardJson(gpa: Allocator, board: *pcb.Board) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "name", try ju.strVal(gpa, board.name));
    try ju.putKey(gpa, &obj.object, "width", .{ .float = board.bounds.width() });
    try ju.putKey(gpa, &obj.object, "height", .{ .float = board.bounds.height() });
    try ju.putKey(gpa, &obj.object, "trace_width", .{ .float = board.trace_width });
    try ju.putKey(gpa, &obj.object, "components", .{ .integer = @intCast(board.components.items.len) });
    try ju.putKey(gpa, &obj.object, "pads", .{ .integer = @intCast(board.pads.items.len) });
    try ju.putKey(gpa, &obj.object, "holes", .{ .integer = @intCast(board.holes.items.len) });
    try ju.putKey(gpa, &obj.object, "rat_length", .{ .float = try board.totalRatLength() });
    return obj;
}

pub fn strArray(gpa: Allocator, items: []const []const u8) !std.json.Value {
    var arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, arr);
    for (items) |s| try arr.array.append(try ju.strVal(gpa, s));
    return arr;
}

fn pathWithoutQuery(raw: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    return raw[0..q];
}

fn jsonResponse(gpa: Allocator, status: u16, value: std.json.Value) !Response {
    const body = try ju.stringifyAlloc(gpa, value);
    ju.freeJsonValue(gpa, value);
    return .{ .status = status, .content_type = json_content_type, .body = body };
}

pub fn errorResponse(gpa: Allocator, status: u16, message: []const u8) !Response {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "error", try ju.strVal(gpa, message));
    return jsonResponse(gpa, status, obj);
}

// --- 测试 ---

const StubState = struct {
    reply: []const u8 = "stub",
    deltas: []const []const u8 = &.{},
};

fn stubResponder(ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef) anyerror!llm.Completion {
    _ = messages;
    _ = defs;
    const st = @as(*StubState, @ptrCast(@alignCast(ctx)));
    return .{ .content = try gpa.dupe(u8, st.reply), .finish_reason = .stop };
}

fn stubStreamResponder(ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef, sink: llm.StreamSink) anyerror!llm.Completion {
    _ = messages;
    _ = defs;
    const st = @as(*StubState, @ptrCast(@alignCast(ctx)));
    for (st.deltas) |d| sink.emit(sink.ctx, .{ .delta = d });
    return .{ .content = try gpa.dupe(u8, st.reply), .finish_reason = .stop };
}

fn echoTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const text = ju.objStr(args.object, "text");
    return .{ .ok = true, .content = try ctx.gpa.dupe(u8, text) };
}

test "http routes" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    var bus = events.EventBus.init(gpa);
    defer bus.deinit();
    var k = kernel.Kernel.init(gpa, &reg);
    defer k.deinit();
    var client = llm.Client.init(gpa, .{ .model = "test-model" });

    const schema = try ju.parseValue(gpa, "{}");
    defer ju.freeJsonValue(gpa, schema);
    try reg.register(.{ .name = "echo", .description = "echo", .parameters = schema, .execute = echoTool });

    var state = StubState{ .reply = "hello from agent" };
    var app = App.init(gpa, .{ .policy = &policy, .registry = &reg, .bus = &bus, .plugins = &k, .client = &client });
    defer app.deinit();
    app.responder = stubResponder;
    app.responder_ctx = &state;

    const health = try app.handle("GET", "/api/health", "");
    defer health.free(gpa);
    try std.testing.expectEqual(@as(u16, 200), health.status);
    try std.testing.expect(std.mem.indexOf(u8, health.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health.body, "\"model\":\"test-model\"") != null);

    const missing = try app.handle("GET", "/api/nope", "");
    defer missing.free(gpa);
    try std.testing.expectEqual(@as(u16, 404), missing.status);

    const chat = try app.handle("POST", "/api/chat", "{\"session\":\"s1\",\"message\":\"hi\"}");
    defer chat.free(gpa);
    try std.testing.expectEqual(@as(u16, 200), chat.status);
    try std.testing.expect(std.mem.indexOf(u8, chat.body, "hello from agent") != null);

    const bad = try app.handle("POST", "/api/chat", "{\"message\":\"hi\"}");
    defer bad.free(gpa);
    try std.testing.expectEqual(@as(u16, 400), bad.status);

    const drc = try app.handle("POST", "/api/drc", "{\"id\":\"p1\",\"name\":\"demo\",\"constraints\":[{\"id\":\"r1\",\"kind\":\"trace_width\",\"limit\":0.2,\"direction\":\"min\",\"severity\":\"hard\"}],\"board\":{\"name\":\"b1\",\"width\":20,\"height\":10,\"trace_width\":0.15}}");
    defer drc.free(gpa);
    try std.testing.expectEqual(@as(u16, 200), drc.status);
    try std.testing.expect(std.mem.indexOf(u8, drc.body, "\"passed\":false") != null);

    const tools_json = try app.handle("GET", "/api/tools", "");
    defer tools_json.free(gpa);
    try std.testing.expect(std.mem.indexOf(u8, tools_json.body, "\"echo\"") != null);
}

test "sse event format" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var sse = Sse.init(gpa, &aw.writer);
    const data = try ju.parseValue(gpa, "{\"text\":\"hi\"}");
    defer ju.freeJsonValue(gpa, data);
    try sse.event("delta", data);
    try std.testing.expectEqualStrings("event: delta\ndata: {\"text\":\"hi\"}\n\n", aw.written());
}

test "chat stream emits events" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    var bus = events.EventBus.init(gpa);
    defer bus.deinit();
    var k = kernel.Kernel.init(gpa, &reg);
    defer k.deinit();
    var client = llm.Client.init(gpa, .{});

    const schema = try ju.parseValue(gpa, "{}");
    defer ju.freeJsonValue(gpa, schema);
    try reg.register(.{ .name = "echo", .description = "echo", .parameters = schema, .execute = echoTool });

    var state = StubState{ .reply = "streamed", .deltas = &.{ "a", "b" } };
    var app = App.init(gpa, .{ .policy = &policy, .registry = &reg, .bus = &bus, .plugins = &k, .client = &client });
    defer app.deinit();
    app.stream_responder = stubStreamResponder;
    app.stream_responder_ctx = &state;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var sse = Sse.init(gpa, &aw.writer);
    try app.chatStream("s2", "hello", &sse);

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "event: session") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "event: delta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "event: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "streamed") != null);
}
