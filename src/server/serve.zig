//! 原生 HTTP / WebSocket 服务层：只负责收发与写回，业务状态全部复用
//! `server/http.zig` 的 App 与 `server/rpc.zig` 的 JSON-RPC 分发。
//!
//! 路由：
//!   GET  /api/*            —— App.handle（health / sessions / tools / plugins / metrics）
//!   POST /api/chat         —— 一轮对话
//!   POST /api/chat/stream  —— SSE 流式对话
//!   GET  /api/ws           —— WebSocket 升级，文本帧即 JSON-RPC
//!   GET  /*                —— 前端静态资源（apps/web/dist）

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ju = @import("../core/jsonutil.zig");
const host = @import("../host.zig");
const http = @import("http.zig");
const rpc = @import("rpc.zig");
const ws = @import("websocket.zig");

pub const default_port: u16 = 8788;
pub const default_bind: []const u8 = "127.0.0.1";
pub const default_static_root: []const u8 = "apps/web/dist";
pub const max_body_bytes: usize = 1024 * 1024;

pub const ServeError = error{
    MissingWebSocketKey,
    UpgradeRequired,
    PathOutsideWorkspace,
};

pub const Options = struct {
    port: u16 = default_port,
    bind: []const u8 = default_bind,
    static_root: []const u8 = default_static_root,
    max_rounds: usize = 12,
};

/// 从原始 head 缓冲区取头部值（std.http.Server.Head 不保留通用头部）。
pub fn headerFromHead(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, head_buffer, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(trimmed[0..colon], name)) continue;
        return std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    }
    return null;
}

pub fn pathWithoutQuery(target: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, target, '#');
    const without_fragment = if (hash) |h| target[0..h] else target;
    const q = std.mem.indexOfScalar(u8, without_fragment, '?');
    return if (q) |i| without_fragment[0..i] else without_fragment;
}

pub fn contentTypeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return http.json_content_type;
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    return "text/plain; charset=utf-8";
}

/// 静态资源路径：拒绝 `..`，避免越界读取。
pub fn staticFilePath(gpa: Allocator, root: []const u8, route: []const u8) ![]const u8 {
    const clean = std.mem.trim(u8, route, "/");
    if (std.mem.indexOf(u8, clean, "..") != null) return error.PathOutsideWorkspace;
    if (clean.len == 0) return std.fmt.allocPrint(gpa, "{s}/index.html", .{root});
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, clean });
}

/// 单条 WebSocket 文本帧 -> JSON-RPC 响应（纯函数，便于测试）。
pub fn wsTextReply(gpa: Allocator, server: *rpc.Rpc, text: []const u8) ![]const u8 {
    _ = gpa;
    return server.call(text);
}

pub fn run(gpa: Allocator, h: *host.Host, opts: Options, err: *std.Io.Writer) !void {
    var app = h.app();
    defer app.deinit();
    app.max_rounds = opts.max_rounds;

    var server = rpc.Rpc.init(gpa, &app);

    var addr = try std.net.Address.parseIp(opts.bind, opts.port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    err.print("CuteClaw Design Agent 已监听 http://{s}:{d}（静态资源 {s}）\n", .{ opts.bind, opts.port, opts.static_root }) catch {};
    err.flush() catch {};

    while (true) {
        var conn = listener.accept() catch |e| {
            err.print("accept 失败: {s}\n", .{@errorName(e)}) catch {};
            continue;
        };
        defer conn.stream.close();
        handleConnection(gpa, &app, &server, &conn, opts, err) catch |e| {
            err.print("连接处理失败: {s}\n", .{@errorName(e)}) catch {};
            err.flush() catch {};
        };
    }
}

fn handleConnection(gpa: Allocator, app: *http.App, server: *rpc.Rpc, conn: *std.net.Server.Connection, opts: Options, err: *std.Io.Writer) !void {
    var recv_buf: [8192]u8 = undefined;
    var send_buf: [65536]u8 = undefined;
    var conn_reader = conn.stream.reader(&recv_buf);
    var conn_writer = conn.stream.writer(&send_buf);
    const reader = conn_reader.interface();
    const writer = &conn_writer.interface;

    var hserv = std.http.Server.init(reader, writer);
    var request = try hserv.receiveHead();

    const route = pathWithoutQuery(request.head.target);
    const method = std.fmt.allocPrint(gpa, "{s}", .{@tagName(request.head.method)}) catch return;
    defer gpa.free(method);

    // WebSocket：自行完成升级，之后按帧处理 JSON-RPC。
    if (std.mem.eql(u8, route, "/api/ws")) {
        const key = headerFromHead(request.head_buffer, "sec-websocket-key") orelse return error.MissingWebSocketKey;
        const upgrade = headerFromHead(request.head_buffer, "upgrade") orelse return error.UpgradeRequired;
        if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.UpgradeRequired;

        const handshake = try ws.handshakeResponse(gpa, key);
        defer gpa.free(handshake);
        try writer.writeAll(handshake);
        try writer.flush();
        // 升级之后改用直接的 socket 读写：std.Io 的 reader/writer 在长连接上会
        // 把缓冲里的残留字节当成 EOF，帧也就永远发不出去。
        try wsLoop(gpa, server, conn.stream, reader.buffer[reader.seek..reader.end]);
        return;
    }

    // 请求体：注意 defer 必须放在函数作用域——若放在下面的 if 块里，body 会在
    // 使用之前就被释放（DebugAllocator 会直接 unmap 空 bucket 的 node）。
    const content_length = request.head.content_length;
    var body: []const u8 = "";
    if (content_length) |cl| {
        if (cl > max_body_bytes) return error.StreamTooLong;
        var body_scratch: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_scratch);
        body = try body_reader.readAlloc(gpa, cl);
    }
    defer gpa.free(body);

    // SSE 流式对话
    if (std.mem.eql(u8, route, "/api/chat/stream")) {
        const req = try ju.parseValue(gpa, body);
        defer ju.freeJsonValue(gpa, req);
        if (req != .object) return error.InvalidRequest;
        const session_id = ju.objStr(req.object, "session");
        const text = ju.objStr(req.object, "message");
        if (session_id.len == 0 or text.len == 0) return error.InvalidRequest;

        var sse_buf: [8192]u8 = undefined;
        var body_writer = try request.respondStreaming(&sse_buf, .{
            .respond_options = .{
                .extra_headers = &.{ .{ .name = "content-type", .value = http.sse_content_type }, .{ .name = "cache-control", .value = "no-cache" } },
                .keep_alive = false,
            },
        });

        var sse = http.Sse.init(gpa, &body_writer.writer);
        try app.chatStream(session_id, text, &sse);
        try body_writer.flush();
        return;
    }

    if (!std.mem.startsWith(u8, route, "/api/")) {
        const path = try staticFilePath(gpa, opts.static_root, route);
        defer gpa.free(path);
        const raw = std.fs.cwd().readFileAlloc(gpa, path, max_body_bytes) catch |e| {
            if (e == error.FileNotFound) {
                const resp = try http.errorResponse(gpa, 404, "not found");
                defer resp.free(gpa);
                try request.respond(resp.body, .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = http.json_content_type }} });
                return;
            }
            return e;
        };
        defer gpa.free(raw);
        try request.respond(raw, .{ .extra_headers = &.{.{ .name = "content-type", .value = contentTypeFor(path) }} });
        return;
    }

    const resp = try app.handle(method, route, body);
    defer resp.free(gpa);
    try request.respond(resp.body, .{
        .status = statusFromCode(resp.status),
        .extra_headers = &.{.{ .name = "content-type", .value = resp.content_type }},
    });
    err.print("{s} {s} {d}\n", .{ method, route, resp.status }) catch {};
}

fn wsLoop(gpa: Allocator, server: *rpc.Rpc, stream: std.net.Stream, pending: []const u8) !void {
    var scratch: [4096]u8 = undefined;
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    try acc.appendSlice(gpa, pending);

    var need_read = pending.len == 0;
    while (true) {
        if (need_read) {
            const n = try posix.read(stream.handle, &scratch);
            if (n == 0) return; // 对端关闭
            try acc.appendSlice(gpa, scratch[0..n]);
        }

        const frame = ws.parseFrame(gpa, acc.items) catch |e| switch (e) {
            error.ShortFrame => {
                need_read = true;
                continue;
            },
            else => return e,
        };
        defer frame.free(gpa);

        // 一次 read 可能带回来好几条帧：只保留属于下一帧的字节。
        const leftover = acc.items[frame.consumed..];
        const kept = try gpa.alloc(u8, leftover.len);
        defer gpa.free(kept);
        @memcpy(kept, leftover);
        acc.clearRetainingCapacity();
        try acc.appendSlice(gpa, kept);
        need_read = kept.len == 0;

        switch (frame.opcode) {
            .close => {
                try writeFrame(gpa, stream, .close, frame.payload);
                return;
            },
            .ping => try writeFrame(gpa, stream, .pong, frame.payload),
            .text, .binary => {
                const reply = try wsTextReply(gpa, server, frame.payload);
                defer gpa.free(reply);
                try writeFrame(gpa, stream, .text, reply);
            },
            .pong => {},
            .continuation => {},
        }
    }
}

fn writeFrame(gpa: Allocator, stream: std.net.Stream, opcode: ws.Opcode, payload: []const u8) !void {
    const encoded = try ws.encodeFrame(gpa, opcode, payload);
    defer gpa.free(encoded);
    var written: usize = 0;
    while (written < encoded.len) {
        const n = try posix.write(stream.handle, encoded[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

fn statusFromCode(code: u16) std.http.Status {
    return switch (code) {
        200 => .ok,
        201 => .created,
        204 => .no_content,
        400 => .bad_request,
        401 => .unauthorized,
        403 => .forbidden,
        404 => .not_found,
        405 => .method_not_allowed,
        409 => .conflict,
        422 => .unprocessable_entity,
        500 => .internal_server_error,
        502 => .bad_gateway,
        else => .ok,
    };
}

test "serve header lookup from raw head buffer" {
    const head = "GET /api/ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGVzdA==\r\nContent-Type: application/json\r\n";
    try std.testing.expectEqualStrings("dGVzdA==", headerFromHead(head, "sec-websocket-key").?);
    try std.testing.expectEqualStrings("websocket", headerFromHead(head, "Upgrade").?);
    try std.testing.expect(headerFromHead(head, "x-nope") == null);
    try std.testing.expectEqualStrings("/api/ws", pathWithoutQuery("/api/ws?session=s1"));
}

test "serve static path and content type" {
    const gpa = std.testing.allocator;
    const p = try staticFilePath(gpa, "apps/web/dist", "/assets/app.js");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("apps/web/dist/assets/app.js", p);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", contentTypeFor(p));

    const index = try staticFilePath(gpa, "apps/web/dist", "/");
    defer gpa.free(index);
    try std.testing.expectEqualStrings("apps/web/dist/index.html", index);
    try std.testing.expectError(error.PathOutsideWorkspace, staticFilePath(gpa, "apps/web/dist", "/../etc/passwd"));
}

test "serve websocket text frame maps to rpc" {
    const gpa = std.testing.allocator;
    const h = try host.Host.init(gpa, .{ .model = "m" }, .{});
    defer h.free();
    var app = h.app();
    defer app.deinit();
    var server = rpc.Rpc.init(gpa, &app);

    const reply = try wsTextReply(gpa, &server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"health\"}");
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"id\":1") != null);

    const frame = try ws.encodeFrame(gpa, .text, reply);
    defer gpa.free(frame);
    var parsed = try ws.parseFrame(gpa, frame);
    defer parsed.free(gpa);
    try std.testing.expectEqual(ws.Opcode.text, parsed.opcode);
}
