//! Agent 主循环：LLM 响应 → 工具执行 → 结果回写，直到无工具调用或达到轮次上限。

const std = @import("std");
const ju = @import("jsonutil.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const session = @import("session.zig");
const events = @import("events.zig");
const memory = @import("../memory.zig");

const Allocator = std.mem.Allocator;

pub const Responder = *const fn (ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef) anyerror!llm.Completion;

pub const TurnResult = struct {
    content: []const u8,
    rounds: usize,
    tool_calls: usize,
    outcome: memory.TaskOutcome,
};

pub const Agent = struct {
    gpa: Allocator,
    session: *session.Session,
    registry: *tools.Registry,
    tool_ctx: *tools.ToolCtx,
    bus: ?*events.EventBus = null,
    max_rounds: usize = 12,
    responder: Responder,
    responder_ctx: *anyopaque,

    pub fn init(gpa: Allocator, sess: *session.Session, registry: *tools.Registry, tool_ctx: *tools.ToolCtx) Agent {
        return .{
            .gpa = gpa,
            .session = sess,
            .registry = registry,
            .tool_ctx = tool_ctx,
            .responder = llmResponder,
            .responder_ctx = undefined,
        };
    }

    pub fn runTurn(self: *Agent, user_text: []const u8) !TurnResult {
        try self.session.append(.{ .role = .user, .content = user_text });

        var rounds: usize = 0;
        var executed: usize = 0;
        var last: []const u8 = "";

        while (rounds < self.max_rounds) {
            rounds += 1;
            const prompt = try self.session.prompt();
            defer session.Session.freePrompt(self.gpa, prompt);

            const defs = try self.registry.toolDefs();
            defer self.gpa.free(defs);

            const completion = try self.responder(self.responder_ctx, self.gpa, prompt, defs);
            defer llm.freeCompletion(self.gpa, completion);

            try self.session.append(.{
                .role = .assistant,
                .content = completion.content,
                .reasoning = completion.reasoning,
                .tool_calls = completion.tool_calls,
            });
            last = completion.content;

            if (completion.tool_calls.len == 0) {
                return .{
                    .content = try self.gpa.dupe(u8, last),
                    .rounds = rounds,
                    .tool_calls = executed,
                    .outcome = .success,
                };
            }

            for (completion.tool_calls) |tc| {
                const args = try ju.parseValue(self.gpa, tc.arguments);
                defer ju.freeJsonValue(self.gpa, args);

                const res = self.registry.execute(self.tool_ctx, tc.name, args) catch |err| {
                    const text = try std.fmt.allocPrint(self.gpa, "tool {s} failed: {s}", .{ tc.name, @errorName(err) });
                    defer self.gpa.free(text);
                    try self.session.append(.{ .role = .tool, .content = text, .tool_call_id = tc.id });
                    executed += 1;
                    continue;
                };
                defer res.free(self.gpa);
                executed += 1;
                try self.session.append(.{ .role = .tool, .content = res.content, .tool_call_id = tc.id });

                if (self.bus) |bus| {
                    var payload = ju.newObj(self.gpa);
                    try ju.putKey(self.gpa, &payload.object, "tool", try ju.strVal(self.gpa, tc.name));
                    try ju.putKey(self.gpa, &payload.object, "ok", .{ .bool = res.ok });
                    defer ju.freeJsonValue(self.gpa, payload);
                    _ = try bus.dispatch("agent.tool", payload, .emit);
                }
            }
        }

        return .{
            .content = try self.gpa.dupe(u8, last),
            .rounds = rounds,
            .tool_calls = executed,
            .outcome = .needs_human,
        };
    }
};

fn llmResponder(ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef) anyerror!llm.Completion {
    _ = gpa;
    const client = @as(*llm.Client, @ptrCast(@alignCast(ctx)));
    return client.complete(messages, defs);
}

const StubState = struct {
    replies: []const llm.Completion,
    index: usize = 0,
};

fn stubResponder(ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef) anyerror!llm.Completion {
    _ = messages;
    _ = defs;
    const st = @as(*StubState, @ptrCast(@alignCast(ctx)));
    const reply = st.replies[st.index];
    st.index += 1;

    // 测试桩同样遵守「Completion 由 gpa 持有」的所有权约定：
    // 直接返回静态切片会让调用方 freeCompletion 释放非分配内存。
    var calls: []llm.ToolCall = &.{};
    if (reply.tool_calls.len > 0) {
        calls = try gpa.alloc(llm.ToolCall, reply.tool_calls.len);
        errdefer gpa.free(calls);
        for (reply.tool_calls, 0..) |tc, i| {
            errdefer gpa.free(calls[i].id);
            calls[i] = .{
                .id = try gpa.dupe(u8, tc.id),
                .name = try gpa.dupe(u8, tc.name),
                .arguments = try gpa.dupe(u8, tc.arguments),
            };
        }
    }
    return .{
        .content = try gpa.dupe(u8, reply.content),
        .reasoning = try gpa.dupe(u8, reply.reasoning),
        .tool_calls = calls,
        .finish_reason = reply.finish_reason,
        .usage = reply.usage,
    };
}

fn echoTool(ctx: *ToolCtxAlias, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const text = ju.objStr(args.object, "text");
    return .{ .ok = true, .content = try gpa.dupe(u8, text) };
}

const ToolCtxAlias = tools.ToolCtx;

test "agent loop with tool call" {
    const gpa = std.testing.allocator;
    var policy = @import("../sandbox/policy.zig").Policy.init(gpa, "ws");
    try policy.grant(.run_tool);

    var registry = tools.Registry.init(gpa);
    defer registry.deinit();
    const schema = try ju.parseValue(gpa, "{}");
    defer ju.freeJsonValue(gpa, schema);
    try registry.register(.{ .name = "echo", .description = "echo", .parameters = schema, .execute = echoTool });

    var sess = session.Session.init(gpa, "s", "model", "sys");
    defer sess.deinit();

    var tool_ctx = tools.ToolCtx{ .gpa = gpa, .policy = &policy };
    var agent = Agent.init(gpa, &sess, &registry, &tool_ctx);

    const call = [_]llm.ToolCall{.{ .id = "c1", .name = "echo", .arguments = "{\"text\":\"pong\"}" }};
    var stub = StubState{ .replies = &.{
        .{ .content = "", .tool_calls = &call, .finish_reason = .tool_calls },
        .{ .content = "done", .finish_reason = .stop },
    } };
    agent.responder = stubResponder;
    agent.responder_ctx = &stub;

    const res = try agent.runTurn("ping");
    defer gpa.free(res.content);
    try std.testing.expectEqualStrings("done", res.content);
    try std.testing.expectEqual(@as(usize, 2), res.rounds);
    try std.testing.expectEqual(@as(usize, 1), res.tool_calls);
    try std.testing.expectEqual(memory.TaskOutcome.success, res.outcome);
    try std.testing.expectEqual(@as(usize, 4), sess.messages.items.len);
}

test "agent max rounds guard" {
    const gpa = std.testing.allocator;
    var policy = @import("../sandbox/policy.zig").Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var registry = tools.Registry.init(gpa);
    defer registry.deinit();
    var sess = session.Session.init(gpa, "s", "model", "");
    defer sess.deinit();
    var tool_ctx = tools.ToolCtx{ .gpa = gpa, .policy = &policy };
    var agent = Agent.init(gpa, &sess, &registry, &tool_ctx);
    agent.max_rounds = 1;

    const call = [_]llm.ToolCall{.{ .id = "c1", .name = "missing", .arguments = "{}" }};
    var stub = StubState{ .replies = &.{.{ .content = "x", .tool_calls = &call, .finish_reason = .length }} };
    agent.responder = stubResponder;
    agent.responder_ctx = &stub;

    const res = try agent.runTurn("hi");
    defer gpa.free(res.content);
    try std.testing.expectEqual(@as(usize, 1), res.rounds);
    try std.testing.expectEqual(memory.TaskOutcome.needs_human, res.outcome);
}
