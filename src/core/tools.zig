//! 工具注册表：插件与内置工具统一入口，含 guardrail 前置/后置钩子与事件派发。

const std = @import("std");
const ju = @import("jsonutil.zig");
const events = @import("events.zig");
const llm = @import("llm.zig");
const sandbox = @import("../sandbox/policy.zig");

const Allocator = std.mem.Allocator;

pub const ToolError = error{
    UnknownTool,
    GuardrailDenied,
    HandlerFailed,
    OutOfMemory,
    CapabilityDenied,
    PathOutsideWorkspace,
    PathDenied,
};

pub const ToolResult = struct {
    ok: bool,
    content: []const u8,
    meta: std.json.Value = .null,

    pub fn free(self: *const ToolResult, gpa: Allocator) void {
        gpa.free(self.content);
        ju.freeJsonValue(gpa, self.meta);
    }
};

pub const ToolCtx = struct {
    gpa: Allocator,
    policy: *sandbox.Policy,
    bus: ?*events.EventBus = null,
    session_id: []const u8 = "",
    project: []const u8 = "",
    /// 工具层上下文（例如 design.Workspace），由调用方注入。
    workspace: ?*anyopaque = null,
};

pub const ToolFn = *const fn (ctx: *ToolCtx, args: std.json.Value) anyerror!ToolResult;
pub const PreHook = *const fn (ctx: *ToolCtx, name: []const u8, args: std.json.Value) anyerror!bool;
pub const PostHook = *const fn (ctx: *ToolCtx, name: []const u8, args: std.json.Value, res: ToolResult) anyerror!void;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    plugin_id: []const u8 = "core",
    execute: ToolFn,
};

pub const Registry = struct {
    gpa: Allocator,
    tools: std.StringHashMap(Tool),
    pre_hooks: std.ArrayList(PreHook),
    post_hooks: std.ArrayList(PostHook),

    pub fn init(gpa: Allocator) Registry {
        return .{
            .gpa = gpa,
            .tools = std.StringHashMap(Tool).init(gpa),
            .pre_hooks = .empty,
            .post_hooks = .empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.tools.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            ju.freeJsonValue(self.gpa, e.value_ptr.parameters);
        }
        self.tools.deinit();
        self.pre_hooks.deinit(self.gpa);
        self.post_hooks.deinit(self.gpa);
    }

    /// 注册表持有 parameters 的副本：调用方仍可释放自己解析出来的 schema。
    pub fn register(self: *Registry, tool: Tool) !void {
        const key = try self.gpa.dupe(u8, tool.name);
        errdefer self.gpa.free(key);
        const params = try ju.copyJsonValue(self.gpa, tool.parameters);
        try self.tools.put(key, .{
            .name = key,
            .description = tool.description,
            .parameters = params,
            .execute = tool.execute,
        });
    }

    pub fn unregister(self: *Registry, name: []const u8) bool {
        const entry = self.tools.getEntry(name) orelse return false;
        self.gpa.free(entry.key_ptr.*);
        _ = self.tools.remove(name);
        return true;
    }

    pub fn count(self: *Registry) usize {
        return self.tools.count();
    }

    pub fn addPreHook(self: *Registry, hook: PreHook) !void {
        try self.pre_hooks.append(self.gpa, hook);
    }

    pub fn addPostHook(self: *Registry, hook: PostHook) !void {
        try self.post_hooks.append(self.gpa, hook);
    }

    pub fn toolDefs(self: *Registry) ![]ToolDefView {
        var out: std.ArrayList(ToolDefView) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |e| {
            try out.append(self.gpa, .{
                .name = e.key_ptr.*,
                .description = e.value_ptr.description,
                .parameters = e.value_ptr.parameters,
            });
        }
        return out.toOwnedSlice(self.gpa);
    }

    pub const ToolDefView = llm.ToolDef;

    /// 执行一次工具调用：guardrail → 事件 waterfall（插件可改写参数）→ 执行 → 后置钩子。
    pub fn execute(self: *Registry, ctx: *ToolCtx, name: []const u8, args: std.json.Value) !ToolResult {
        const tool = self.tools.get(name) orelse return error.UnknownTool;
        try ctx.policy.checkCapability(.run_tool);

        for (self.pre_hooks.items) |h| {
            if (!try h(ctx, name, args)) return error.GuardrailDenied;
        }

        var effective = args;
        if (ctx.bus) |bus| {
            const rewritten = try bus.dispatch("tool.pre", args, .waterfall);
            if (rewritten != .null) effective = rewritten;
        }

        const res = try tool.execute(ctx, effective);

        if (ctx.bus) |bus| {
            const payload = try buildResultPayload(self.gpa, name, res);
            defer ju.freeJsonValue(self.gpa, payload);
            _ = try bus.dispatch("tool.post", payload, .emit);
        }

        for (self.post_hooks.items) |h| try h(ctx, name, effective, res);
        return res;
    }
};

fn buildResultPayload(gpa: Allocator, name: []const u8, res: ToolResult) !std.json.Value {
    var obj = ju.newObj(gpa);
    try ju.putKey(gpa, &obj.object, "tool", try ju.strVal(gpa, name));
    try ju.putKey(gpa, &obj.object, "ok", .{ .bool = res.ok });
    try ju.putKey(gpa, &obj.object, "content", try ju.strVal(gpa, res.content));
    return obj;
}

fn echoTool(ctx: *ToolCtx, args: std.json.Value) anyerror!ToolResult {
    const text = ju.objStr(args.object, "text");
    return .{ .ok = true, .content = try ctx.gpa.dupe(u8, text) };
}

fn denyAllPre(ctx: *ToolCtx, name: []const u8, args: std.json.Value) anyerror!bool {
    _ = ctx;
    _ = args;
    return !std.mem.eql(u8, name, "echo");
}

test "tool registry dispatch" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const schema = try ju.parseValue(gpa, "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}");
    defer ju.freeJsonValue(gpa, schema);
    try reg.register(.{ .name = "echo", .description = "echo", .parameters = schema, .execute = echoTool });
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    var ctx = ToolCtx{ .gpa = gpa, .policy = &policy };
    const args = try ju.parseValue(gpa, "{\"text\":\"hi\"}");
    defer ju.freeJsonValue(gpa, args);
    const res = try reg.execute(&ctx, "echo", args);
    defer res.free(gpa);
    try std.testing.expect(res.ok);
    try std.testing.expectEqualStrings("hi", res.content);

    try std.testing.expectError(error.UnknownTool, reg.execute(&ctx, "missing", args));
}

test "guardrail hook" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const schema = try ju.parseValue(gpa, "{}");
    defer ju.freeJsonValue(gpa, schema);
    try reg.register(.{ .name = "echo", .description = "echo", .parameters = schema, .execute = echoTool });
    try reg.addPreHook(denyAllPre);

    var ctx = ToolCtx{ .gpa = gpa, .policy = &policy };
    const args = try ju.parseValue(gpa, "{\"text\":\"hi\"}");
    defer ju.freeJsonValue(gpa, args);
    try std.testing.expectError(error.GuardrailDenied, reg.execute(&ctx, "echo", args));
}
