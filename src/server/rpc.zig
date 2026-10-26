//! JSON-RPC 2.0 方法分发：复用 MCP 消息形状，把方法映射到 HTTP App 的同一状态。
//! 与 `tools/list` / `tools/call` 一起构成前端与插件共用的调用面。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("../core/jsonutil.zig");
const llm = @import("../core/llm.zig");
const tools = @import("../core/tools.zig");
const events = @import("../core/events.zig");
const sandbox = @import("../sandbox/policy.zig");
const kernel = @import("../plugins/kernel.zig");
const mcp = @import("../plugins/mcp.zig");
const http = @import("http.zig");

pub const code_invalid_request = -32600;
pub const code_method_not_found = -32601;
pub const code_invalid_params = -32602;
pub const code_internal = -32603;

pub const Rpc = struct {
    gpa: Allocator,
    app: *http.App,
    server: mcp.Server,

    pub fn init(gpa: Allocator, app: *http.App) Rpc {
        return .{
            .gpa = gpa,
            .app = app,
            .server = .{
                .gpa = gpa,
                .handler = rpcHandler,
                .handler_ctx = @ptrCast(app),
                .registry = app.registry,
                .tool_ctx = &app.tool_ctx,
            },
        };
    }

    pub fn call(self: *Rpc, text: []const u8) ![]const u8 {
        return self.server.handle(text);
    }
};

fn rpcHandler(ctx: *anyopaque, gpa: Allocator, method: []const u8, params: std.json.Value) anyerror!std.json.Value {
    _ = gpa;
    const app = @as(*http.App, @ptrCast(@alignCast(ctx)));

    if (std.mem.eql(u8, method, "health")) return app.healthJson();
    if (std.mem.eql(u8, method, "sessions")) return app.sessionsJson();
    if (std.mem.eql(u8, method, "plugins.list")) return app.pluginsJson();
    if (std.mem.eql(u8, method, "metrics")) return app.metricsJson();

    if (std.mem.eql(u8, method, "chat")) {
        if (params != .object) return error.InvalidRequest;
        const id = ju.objStr(params.object, "session");
        const text = ju.objStr(params.object, "message");
        if (id.len == 0 or text.len == 0) return error.InvalidRequest;
        return app.chat(id, text);
    }

    if (std.mem.eql(u8, method, "drc")) {
        if (params != .object) return error.InvalidRequest;
        return app.drcJson(params);
    }

    return error.MethodNotFound;
}

fn echoTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const text = ju.objStr(args.object, "text");
    return .{ .ok = true, .content = try gpa.dupe(u8, text) };
}

const StubState = struct { reply: []const u8 = "rpc reply" };

fn stubResponder(ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef) anyerror!llm.Completion {
    _ = messages;
    _ = defs;
    const st = @as(*StubState, @ptrCast(@alignCast(ctx)));
    return .{ .content = try gpa.dupe(u8, st.reply), .finish_reason = .stop };
}

test "rpc dispatch to app" {
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

    var app = http.App.init(gpa, .{
        .policy = &policy,
        .registry = &reg,
        .bus = &bus,
        .plugins = &k,
        .client = &client,
    });
    defer app.deinit();
    app.responder = stubResponder;
    var state = StubState{};
    app.responder_ctx = &state;

    var rpc = Rpc.init(gpa, &app);
    const resp = try rpc.call("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"chat\",\"params\":{\"session\":\"s1\",\"message\":\"hi\"}}");
    defer gpa.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "rpc reply") != null);

    const listed = try rpc.call("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"echo\"") != null);

    const called = try rpc.call("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"ping\"}}}");
    defer gpa.free(called);
    try std.testing.expect(std.mem.indexOf(u8, called, "ping") != null);

    const unknown = try rpc.call("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"nope\"}");
    defer gpa.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "-32601") != null);
}
