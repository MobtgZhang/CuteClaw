//! MCP / JSON-RPC 2.0：消息形状、方法分发与 stdio 传输。工具层复用 core 的工具注册表。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const tools = @import("../core/tools.zig");

const Allocator = std.mem.Allocator;

pub const RpcError = error{
    InvalidRequest,
    MethodNotFound,
    HandlerFailed,
    OutOfMemory,
};

pub const Message = struct {
    id: ?i64 = null,
    method: []const u8 = "",
    params: std.json.Value = .null,
    result: std.json.Value = .null,
    error_code: ?i32 = null,
    error_message: []const u8 = "",

    pub fn isResponse(self: Message) bool {
        return self.error_code != null or self.result != .null;
    }

    pub fn free(self: *const Message, gpa: Allocator) void {
        ju.freeJsonValue(gpa, self.params);
        ju.freeJsonValue(gpa, self.result);
        gpa.free(self.method);
        gpa.free(self.error_message);
    }
};

pub fn parseMessage(gpa: Allocator, text: []const u8) !Message {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;

    var m: Message = .{};
    if (ju.objGet(obj, "id")) |id_v| {
        switch (id_v) {
            .integer => |i| m.id = i,
            .string => |s| m.id = std.fmt.parseInt(i64, s, 10) catch null,
            else => {},
        }
    }
    m.params = try ju.copyJsonValue(gpa, objGetOr(obj, "params"));
    m.result = try ju.copyJsonValue(gpa, objGetOr(obj, "result"));
    m.method = try gpa.dupe(u8, ju.objStr(obj, "method"));
    m.error_message = try gpa.dupe(u8, ju.objStr(obj, "error"));
    if (ju.objGet(obj, "error")) |e_v| {
        if (e_v == .object) m.error_code = @intCast(ju.objNum(e_v.object, "code"));
    }
    return m;
}

fn objGetOr(obj: std.json.ObjectMap, key: []const u8) std.json.Value {
    return ju.objGet(obj, key) orelse .null;
}

pub fn encode(gpa: Allocator, m: Message) ![]const u8 {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "jsonrpc", try ju.strVal(gpa, "2.0"));
    if (m.id) |id| {
        try ju.putKey(gpa, &obj.object, "id", .{ .integer = id });
    } else {
        try ju.putKey(gpa, &obj.object, "id", .null);
    }
    if (m.method.len > 0) try ju.putKey(gpa, &obj.object, "method", try ju.strVal(gpa, m.method));
    if (m.params != .null) try ju.putKey(gpa, &obj.object, "params", try ju.copyJsonValue(gpa, m.params));
    if (m.error_code) |code| {
        var err = ju.newObj(gpa);
        try ju.putKey(gpa, &err.object, "code", .{ .integer = code });
        try ju.putKey(gpa, &err.object, "message", try ju.strVal(gpa, m.error_message));
        try ju.putKey(gpa, &obj.object, "error", err);
    } else {
        try ju.putKey(gpa, &obj.object, "result", try ju.copyJsonValue(gpa, m.result));
    }
    const text = try ju.stringifyAlloc(gpa, obj);
    ju.freeJsonValue(gpa, obj);
    return text;
}

pub const Handler = *const fn (ctx: *anyopaque, gpa: Allocator, method: []const u8, params: std.json.Value) anyerror!std.json.Value;

pub const Server = struct {
    gpa: Allocator,
    handler: Handler,
    handler_ctx: *anyopaque,
    registry: ?*tools.Registry = null,
    tool_ctx: ?*tools.ToolCtx = null,

    pub fn init(gpa: Allocator, handler: Handler, handler_ctx: *anyopaque) Server {
        return .{ .gpa = gpa, .handler = handler, .handler_ctx = handler_ctx };
    }

    pub fn handle(self: *Server, text: []const u8) ![]const u8 {
        const req = try parseMessage(self.gpa, text);
        defer req.free(self.gpa);
        if (req.method.len == 0) return encode(self.gpa, errorResponse(self.gpa, req.id, -32600, "invalid request"));

        var result: std.json.Value = .null;
        if (std.mem.eql(u8, req.method, "tools/list")) {
            result = try listTools(self, self.gpa);
        } else if (std.mem.eql(u8, req.method, "tools/call")) {
            result = try callTool(self, req.params);
        } else {
            result = self.handler(self.handler_ctx, self.gpa, req.method, req.params) catch |err| {
                const code: i32 = if (err == error.MethodNotFound) -32601 else if (err == error.InvalidRequest) -32600 else -32603;
                const err_resp = errorResponse(self.gpa, req.id, code, @errorName(err));
                defer err_resp.free(self.gpa);
                return encode(self.gpa, err_resp);
            };
        }

        const resp = Message{ .id = req.id, .result = result };
        const out = try encode(self.gpa, resp);
        ju.freeJsonValue(self.gpa, result);
        return out;
    }

    fn listTools(self: *Server, gpa: Allocator) !std.json.Value {
        const reg = self.registry orelse return error.MethodNotFound;
        const defs = try reg.toolDefs();
        defer gpa.free(defs);
        var arr = ju.newArr(gpa);
        for (defs) |d| {
            var t = ju.newObj(gpa);
            try ju.putKey(gpa, &t.object, "name", try ju.strVal(gpa, d.name));
            try ju.putKey(gpa, &t.object, "description", try ju.strVal(gpa, d.description));
            try ju.putKey(gpa, &t.object, "inputSchema", try ju.copyJsonValue(gpa, d.parameters));
            try arr.array.append(t);
        }
        return arr;
    }

    fn callTool(self: *Server, params: std.json.Value) !std.json.Value {
        const reg = self.registry orelse return error.MethodNotFound;
        const ctx = self.tool_ctx orelse return error.MethodNotFound;
        if (params != .object) return error.InvalidRequest;
        const name = ju.objStr(params.object, "name");
        const args = ju.objGet(params.object, "arguments") orelse .null;
        const res = try reg.execute(ctx, name, args);
        defer res.free(self.gpa);
        var out = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &out.object, "content", try ju.strVal(self.gpa, res.content));
        try ju.putKey(self.gpa, &out.object, "isError", .{ .bool = !res.ok });
        return out;
    }
};

fn errorResponse(gpa: Allocator, id: ?i64, code: i32, message: []const u8) Message {
    return .{ .id = id, .error_code = code, .error_message = gpa.dupe(u8, message) catch "" };
}

test "json-rpc parse and encode" {
    const gpa = std.testing.allocator;
    const req = try parseMessage(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"vue\"}}}");
    defer req.free(gpa);
    try std.testing.expectEqual(@as(?i64, 7), req.id);
    try std.testing.expectEqualStrings("initialize", req.method);
    try std.testing.expect(!req.isResponse());

    const resp = Message{ .id = req.id, .result = try ju.copyJsonValue(gpa, req.params) };
    defer ju.freeJsonValue(gpa, resp.result);
    const text = try encode(gpa, resp);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"clientInfo\"") != null);
}

fn echoHandler(ctx: *anyopaque, gpa: Allocator, method: []const u8, params: std.json.Value) anyerror!std.json.Value {
    _ = ctx;
    if (std.mem.eql(u8, method, "ping")) return ju.copyJsonValue(gpa, params);
    return error.MethodNotFound;
}

test "mcp tools/list and tools/call" {
    const gpa = std.testing.allocator;
    var policy = @import("../sandbox/policy.zig").Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    const schema = try ju.parseValue(gpa, "{\"type\":\"object\"}");
    defer ju.freeJsonValue(gpa, schema);
    try reg.register(.{ .name = "echo", .description = "echo", .parameters = schema, .execute = mcpEchoTool });

    var ctx = tools.ToolCtx{ .gpa = gpa, .policy = &policy };
    var server = Server.init(gpa, echoHandler, undefined);
    server.registry = &reg;
    server.tool_ctx = &ctx;

    const listed = try server.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"name\":\"echo\"") != null);

    const called = try server.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}");
    defer gpa.free(called);
    try std.testing.expect(std.mem.indexOf(u8, called, "\"content\":\"hi\"") != null);

    const bad = try server.handle("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope\"}");
    defer gpa.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "\"code\":-32601") != null);
}

fn mcpEchoTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    return .{ .ok = true, .content = try ctx.gpa.dupe(u8, ju.objStr(args.object, "text")) };
}
