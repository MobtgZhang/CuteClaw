//! WebSocket（RFC 6455）：握手 accept key（SHA-1 + Base64）与帧编解码。

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const WsError = error{
    ShortFrame,
    BadFrame,
    MaskedServerFrame,
    OutOfMemory,
};

/// RFC 6455 规定的握手魔法 GUID（拼错会导致所有真实客户端握手失败）。
pub const magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub fn sha1(gpa: Allocator, data: []const u8) ![20]u8 {
    var h = [5]u32{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };

    const ml = @as(u64, data.len) * 8;
    var message = std.ArrayList(u8).empty;
    defer message.deinit(gpa);
    try message.appendSlice(gpa, data);
    try message.append(gpa, 0x80);
    while (message.items.len % 64 != 56) try message.append(gpa, 0);
    for (0..8) |idx| {
        const shift: u6 = @intCast(56 - 8 * idx);
        try message.append(gpa, @truncate(ml >> shift));
    }

    var chunk: usize = 0;
    while (chunk < message.items.len) {
        var w: [80]u32 = undefined;
        var t: usize = 0;
        while (t < 16) : (t += 1) {
            // 大端拼字：每个字取 4 个字节（原来用 pow(24, n) 既错又会溢出 u32）。
            const base = chunk + t * 4;
            w[t] = (@as(u32, message.items[base]) << 24) |
                (@as(u32, message.items[base + 1]) << 16) |
                (@as(u32, message.items[base + 2]) << 8) |
                @as(u32, message.items[base + 3]);
        }
        while (t < 80) : (t += 1) {
            const v = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16];
            w[t] = std.math.rotl(u32, v, 1);
        }

        var a = h[0];
        var b = h[1];
        var c = h[2];
        var d = h[3];
        var e = h[4];

        for (0..80) |step| {
            var f: u32 = 0;
            var k: u32 = 0;
            if (step < 20) {
                f = (b & c) | (~b & d);
                k = 0x5A827999;
            } else if (step < 40) {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1;
            } else if (step < 60) {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDC;
            } else {
                f = b ^ c ^ d;
                k = 0xCA62C1D6;
            }
            const tmp = std.math.rotl(u32, a, 5) +% f +% k +% w[step] +% e;
            e = d;
            d = c;
            c = std.math.rotl(u32, b, 30);
            b = a;
            a = tmp;
        }

        h[0] +%= a;
        h[1] +%= b;
        h[2] +%= c;
        h[3] +%= d;
        h[4] +%= e;
        chunk += 64;
    }

    var out: [20]u8 = undefined;
    for (0..5) |idx| {
        out[idx * 4] = @truncate(h[idx] >> 24);
        out[idx * 4 + 1] = @truncate(h[idx] >> 16);
        out[idx * 4 + 2] = @truncate(h[idx] >> 8);
        out[idx * 4 + 3] = @truncate(h[idx]);
    }
    return out;
}

fn hex_digit(nibble: u8) u8 {
    if (nibble < 10) return '0' + nibble;
    return 'a' + (nibble - 10);
}

pub fn acceptKey(gpa: Allocator, client_key: []const u8) ![]const u8 {
    var joined = try gpa.alloc(u8, client_key.len + magic_guid.len);
    defer gpa.free(joined);
    @memcpy(joined[0..client_key.len], client_key);
    @memcpy(joined[client_key.len..], magic_guid);
    const digest = try sha1(gpa, joined);
    const buf = try gpa.alloc(u8, 28);
    return std.base64.standard.Encoder.encode(buf, &digest);
}

pub fn handshakeResponse(gpa: Allocator, client_key: []const u8) ![]const u8 {
    const accept = try acceptKey(gpa, client_key);
    defer gpa.free(accept);
    return std.fmt.allocPrint(gpa, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
}

pub const Frame = struct {
    opcode: Opcode,
    payload: []const u8,
    /// 整帧占用的字节数（含头部与掩码），用于从接收缓冲中剔除已处理的帧。
    consumed: usize = 0,

    pub fn free(self: *const Frame, gpa: Allocator) void {
        gpa.free(self.payload);
    }
};

pub fn parseFrame(gpa: Allocator, bytes: []const u8) !Frame {
    if (bytes.len < 2) return error.ShortFrame;

    const first = bytes[0];
    const second = bytes[1];
    const masked = (second & 0x80) != 0;
    const len7 = second & 0x7F;

    var header: usize = 2;
    var length: usize = len7;
    if (len7 == 126) {
        if (bytes.len < 4) return error.ShortFrame;
        length = (@as(usize, bytes[2]) << 8) | bytes[3];
        header = 4;
    } else if (len7 == 127) {
        if (bytes.len < 10) return error.ShortFrame;
        length = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) length = (length << 8) | bytes[2 + i];
        header = 10;
    }

    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (bytes.len < header + 4) return error.ShortFrame;
        mask = .{ bytes[header], bytes[header + 1], bytes[header + 2], bytes[header + 3] };
        header += 4;
    }

    if (bytes.len < header + length) return error.ShortFrame;

    const payload = try gpa.alloc(u8, length);
    errdefer gpa.free(payload);
    for (0..length) |i| {
        const raw = bytes[header + i];
        payload[i] = if (masked) raw ^ mask[i % 4] else raw;
    }

    const opcode = first & 0x0F;
    if (opcode > 0xA) return error.BadFrame;

    return .{ .opcode = @enumFromInt(opcode), .payload = payload, .consumed = header + length };
}

pub fn encodeFrame(gpa: Allocator, opcode: Opcode, payload: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.append(gpa, 0x80 | @intFromEnum(opcode));
    if (payload.len < 126) {
        try out.append(gpa, @intCast(payload.len));
    } else if (payload.len < 65536) {
        try out.append(gpa, 126);
        try out.append(gpa, @intCast(payload.len >> 8));
        try out.append(gpa, @intCast(payload.len & 0xFF));
    } else {
        try out.append(gpa, 127);
        for (0..8) |idx| {
            const shift: u6 = @intCast(56 - 8 * idx);
            try out.append(gpa, @intCast(payload.len >> shift));
        }
    }
    try out.appendSlice(gpa, payload);
    return out.toOwnedSlice(gpa);
}

test "websocket accept key" {
    const gpa = std.testing.allocator;
    const key = try acceptKey(gpa, "x33R8Hq5dcwmGHw93Ck2YOVz16q");
    defer gpa.free(key);
    try std.testing.expectEqualStrings("WJx8dN9cMIR2RHQYFpqY1sHi+iI=", key);

    const digest = try sha1(gpa, "abc");
    var hex: [40]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_digit(byte >> 4);
        hex[i * 2 + 1] = hex_digit(byte & 0x0F);
    }
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", &hex);

    const response = try handshakeResponse(gpa, "x33R8Hq5dcwmGHw93Ck2YOVz16q");
    defer gpa.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "101 Switching Protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "WJx8dN9cMIR2RHQYFpqY1sHi+iI=") != null);
}

test "frame roundtrip with mask" {
    const gpa = std.testing.allocator;
    const encoded = try encodeFrame(gpa, .text, "hello");
    defer gpa.free(encoded);
    try std.testing.expectEqual(@as(u8, 0x81), encoded[0]);

    // 客户端帧：掩码位置 1，掩码后的载荷必须能还原成原文。
    const mask = [4]u8{ 0x37, 0xFA, 0x21, 0x1D };
    var masked: std.ArrayList(u8) = .empty;
    defer masked.deinit(gpa);
    try masked.appendSlice(gpa, &.{ 0x81, 0x85 });
    try masked.appendSlice(gpa, &mask);
    for ("hello", 0..) |b, i| try masked.append(gpa, b ^ mask[i % 4]);

    const frame = try parseFrame(gpa, masked.items);
    defer frame.free(gpa);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualStrings("hello", frame.payload);

    const long = try encodeFrame(gpa, .binary, "abcdefghij");
    defer gpa.free(long);
    const back = try parseFrame(gpa, long);
    defer back.free(gpa);
    try std.testing.expectEqual(Opcode.binary, back.opcode);
    try std.testing.expectEqualStrings("abcdefghij", back.payload);

    try std.testing.expectError(error.ShortFrame, parseFrame(gpa, &.{0x81}));
}

test "粘包缓冲按 consumed 切分" {
    const gpa = std.testing.allocator;
    const mask = [4]u8{ 0x37, 0xFA, 0x21, 0x1D };

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for ([_]u8{ 0x81, 0x85 }) |b| try stream.append(gpa, b);
    try stream.appendSlice(gpa, &mask);
    for ("hello", 0..) |b, i| try stream.append(gpa, b ^ mask[i % 4]);
    const second = try encodeFrame(gpa, .text, "world");
    defer gpa.free(second);
    try stream.appendSlice(gpa, second);

    const first = try parseFrame(gpa, stream.items);
    defer first.free(gpa);
    try std.testing.expectEqualStrings("hello", first.payload);
    try std.testing.expectEqual(@as(usize, 11), first.consumed);

    const rest = stream.items[first.consumed..];
    const next = try parseFrame(gpa, rest);
    defer next.free(gpa);
    try std.testing.expectEqualStrings("world", next.payload);
    try std.testing.expectEqual(@as(usize, 7), next.consumed);

    // 半帧必须报 ShortFrame，让调用方继续读取。
    try std.testing.expectError(error.ShortFrame, parseFrame(gpa, stream.items[0 .. first.consumed - 3]));
}
