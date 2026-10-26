//! CLI 对话入口：读取配置、装配 Host，单轮（--message）或交互式 REPL。
//! 与 HTTP / WebSocket 走同一条 agent 主循环，保证行为一致。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("core/jsonutil.zig");
const llm = @import("core/llm.zig");
const cli = @import("cli_common.zig");
const http = @import("server/http.zig");
const host = @import("host.zig");

pub const Options = struct {
    session_id: []const u8 = "cli",
    as_json: bool = false,
    max_rounds: usize = 12,
    plugins: []const []const u8 = &.{},
};

pub fn formatReply(gpa: Allocator, reply: std.json.Value, as_json: bool) ![]const u8 {
    if (as_json) return ju.stringifyAlloc(gpa, reply);
    return gpa.dupe(u8, ju.objStr(reply.object, "reply"));
}

pub fn run(gpa: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, argv: []const []const u8, opts: Options) !void {
    const h = try cli.buildHost(gpa, argv, .{ .max_rounds = opts.max_rounds, .plugins = opts.plugins }, err);
    defer h.free();
    var app = h.app();
    defer app.deinit();

    // --session / --json 与 help 中的说明一致：会话 id 与输出格式都可从命令行覆盖。
    const session_id = cli.flagValue(argv, "--session") orelse opts.session_id;
    const as_json = cli.hasFlag(argv, "--json") or opts.as_json;

    if (cli.flagValue(argv, "--message")) |message| {
        const reply = try app.chat(session_id, message);
        defer ju.freeJsonValue(gpa, reply);
        const text = try formatReply(gpa, reply, as_json);
        defer gpa.free(text);
        try out.writeAll(text);
        try out.writeAll("\n");
        try out.flush();
        return;
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const reader = &stdin_reader.interface;

    try out.print("CuteClaw Design Agent — 输入内容开始对话（exit 退出）\n", .{});
    try out.flush();

    while (true) {
        try out.writeAll("> ");
        try out.flush();
        const line = try readLine(gpa, reader) orelse break;
        defer gpa.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "/quit")) break;

        const reply = try app.chat(session_id, trimmed);
        defer ju.freeJsonValue(gpa, reply);

        const tool_calls = ju.objNum(reply.object, "tool_calls");
        if (tool_calls > 0) err.print("（本轮工具调用 {d} 次，轮次 {d}）\n", .{ tool_calls, ju.objNum(reply.object, "rounds") }) catch {};

        const text = try formatReply(gpa, reply, as_json);
        defer gpa.free(text);
        try out.writeAll(text);
        try out.writeAll("\n");
        try out.flush();
    }
}

/// 逐块读取一行：Zig 0.15 的 Reader 没有分隔符读取方法，这里手动累积到换行。
fn readLine(gpa: Allocator, reader: *std.Io.Reader) error{ ReadFailed, OutOfMemory }!?[]const u8 {
    var scratch: [4096]u8 = undefined;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);

    while (true) {
        const n = try reader.readSliceShort(&scratch);
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, scratch[0..n], '\n')) |idx| {
            try line.appendSlice(gpa, scratch[0..idx]);
            return try line.toOwnedSlice(gpa);
        }
        try line.appendSlice(gpa, scratch[0..n]);
    }

    if (line.items.len == 0) return null;
    return try line.toOwnedSlice(gpa);
}

const StubState = struct { reply: []const u8 = "stub reply" };

fn stubResponder(ctx: *anyopaque, gpa: Allocator, messages: []const llm.Message, defs: []const llm.ToolDef) anyerror!llm.Completion {
    _ = messages;
    _ = defs;
    const st = @as(*StubState, @ptrCast(@alignCast(ctx)));
    return .{ .content = try gpa.dupe(u8, st.reply), .finish_reason = .stop };
}

test "chat reply formatting" {
    const gpa = std.testing.allocator;
    const reply = try ju.parseValue(gpa, "{\"session\":\"cli\",\"reply\":\"你好\",\"rounds\":1,\"tool_calls\":0,\"outcome\":\"success\"}");
    defer ju.freeJsonValue(gpa, reply);

    const plain = try formatReply(gpa, reply, false);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("你好", plain);

    const json = try formatReply(gpa, reply, true);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"outcome\":\"success\"") != null);
}

test "chat runs a turn through the host app" {
    const gpa = std.testing.allocator;
    const h = try host.Host.init(gpa, .{ .model = "test-model" }, .{});
    defer h.free();

    var app = h.app();
    defer app.deinit();
    app.responder = stubResponder;
    var state = StubState{};
    app.responder_ctx = &state;

    const reply = try app.chat("cli", "hi");
    defer ju.freeJsonValue(gpa, reply);
    try std.testing.expectEqualStrings("stub reply", ju.objStr(reply.object, "reply"));
    try std.testing.expectEqual(@as(usize, 1), ju.objNum(reply.object, "rounds"));
}
