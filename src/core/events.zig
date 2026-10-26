//! 事件总线：Cordis 风格的 dispatch 模式（emit / waterfall / parallel / serial / bail）
//! 与 JSONL 事件日志。注册均可撤销（reversible），供插件内核使用。

const std = @import("std");
const ju = @import("jsonutil.zig");
const Allocator = std.mem.Allocator;

pub const DispatchMode = enum { emit, waterfall, parallel, serial, bail };

pub fn dispatchModeFromString(s: []const u8) ?DispatchMode {
    if (std.mem.eql(u8, s, "emit")) return .emit;
    if (std.mem.eql(u8, s, "waterfall")) return .waterfall;
    if (std.mem.eql(u8, s, "parallel")) return .parallel;
    if (std.mem.eql(u8, s, "serial")) return .serial;
    if (std.mem.eql(u8, s, "bail")) return .bail;
    return null;
}

pub const Event = struct {
    kind: []const u8,
    ts_unix: i64 = 0,
    payload: std.json.Value = .null,
};

pub const HandlerFn = *const fn (ctx: *anyopaque, gpa: Allocator, ev: Event, acc: std.json.Value) anyerror!std.json.Value;

pub const Handler = struct {
    plugin_id: []const u8,
    priority: i32 = 0,
    ctx: *anyopaque = undefined,
    call: HandlerFn,
};

pub const EventBusError = error{HandlerFailed};

pub const EventBus = struct {
    gpa: Allocator,
    handlers: std.StringHashMap(std.ArrayList(Handler)),

    pub fn init(gpa: Allocator) EventBus {
        return .{ .gpa = gpa, .handlers = std.StringHashMap(std.ArrayList(Handler)).init(gpa) };
    }

    pub fn deinit(self: *EventBus) void {
        var it = self.handlers.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.handlers.deinit();
    }

    pub fn register(self: *EventBus, kind: []const u8, h: Handler) !void {
        const key = try self.gpa.dupe(u8, kind);
        errdefer self.gpa.free(key);
        const entry = try self.handlers.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        } else {
            self.gpa.free(key);
        }
        try entry.value_ptr.append(self.gpa, h);
    }

    pub fn unregister(self: *EventBus, kind: []const u8, plugin_id: []const u8) bool {
        const list = self.handlers.getPtr(kind) orelse return false;
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i].plugin_id, plugin_id)) {
                _ = list.orderedRemove(i);
                return true;
            }
            i += 1;
        }
        return false;
    }

    pub fn count(self: *EventBus, kind: []const u8) usize {
        const list = self.handlers.get(kind) orelse return 0;
        return list.items.len;
    }

    /// `payload` 由调用方拥有；返回值由调用方用 `ju.freeJsonValue` 释放。
    pub fn dispatch(self: *EventBus, kind: []const u8, payload: std.json.Value, mode: DispatchMode) !std.json.Value {
        const list = self.handlers.get(kind) orelse return .null;
        if (list.items.len == 0) return .null;

        var ordered: std.ArrayList(Handler) = .empty;
        defer ordered.deinit(self.gpa);
        for (list.items) |h| try ordered.append(self.gpa, h);
        std.sort.insertion(Handler, ordered.items, {}, priorityLessThan);

        const ev = Event{ .kind = kind, .ts_unix = std.time.milliTimestamp(), .payload = payload };
        var acc: std.json.Value = payload;

        switch (mode) {
            .emit => {
                for (ordered.items) |h| {
                    const res = h.call(h.ctx, self.gpa, ev, .null) catch return error.HandlerFailed;
                    ju.freeJsonValue(self.gpa, res);
                }
                return .null;
            },
            .waterfall => {
                for (ordered.items) |h| {
                    const res = h.call(h.ctx, self.gpa, ev, acc) catch return error.HandlerFailed;
                    if (res != .null) ju.freeJsonValue(self.gpa, acc);
                    acc = res;
                }
                return acc;
            },
            .parallel, .serial => {
                var out = ju.newArr(self.gpa);
                errdefer ju.freeJsonValue(self.gpa, out);
                for (ordered.items) |h| {
                    const res = h.call(h.ctx, self.gpa, ev, acc) catch return error.HandlerFailed;
                    try out.array.append(res);
                }
                return out;
            },
            .bail => {
                for (ordered.items) |h| {
                    const res = h.call(h.ctx, self.gpa, ev, acc) catch return error.HandlerFailed;
                    if (res != .null) return res;
                    ju.freeJsonValue(self.gpa, res);
                }
                return .null;
            },
        }
    }
};

fn priorityLessThan(_: void, a: Handler, b: Handler) bool {
    return a.priority < b.priority;
}

/// 追加式 JSONL 事件日志（审计与进化引擎的证据来源）。
pub const EventLog = struct {
    gpa: Allocator,
    path: []const u8,

    pub fn init(gpa: Allocator, path: []const u8) EventLog {
        return .{ .gpa = gpa, .path = path };
    }

    pub fn append(self: *EventLog, ev: Event) !void {
        const payload = try ju.stringifyAlloc(self.gpa, ev.payload);
        defer self.gpa.free(payload);
        const ts = if (ev.ts_unix == 0) std.time.timestamp() else ev.ts_unix;
        const line = try std.fmt.allocPrint(self.gpa, "{{\"kind\":\"{s}\",\"ts\":{d},\"payload\":{s}}}\n", .{ ev.kind, ts, payload });
        defer self.gpa.free(line);

        const dir = std.fs.path.dirname(self.path);
        if (dir) |d| std.fs.cwd().makePath(d) catch {};
        var file = try std.fs.cwd().createFile(self.path, .{});
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(line);
    }

    pub fn readAll(self: *EventLog) ![]const u8 {
        return std.fs.cwd().readFileAlloc(self.gpa, self.path, 4 * 1024 * 1024);
    }
};

const testBusCtx = struct { seen: usize = 0, mode: []const u8 = "" };

fn testHandler(ctx: *anyopaque, gpa: Allocator, ev: Event, acc: std.json.Value) anyerror!std.json.Value {
    const c = @as(*testBusCtx, @ptrCast(@alignCast(ctx)));
    c.seen += 1;
    c.mode = ev.kind;
    if (std.mem.eql(u8, ev.kind, "bail")) return if (c.seen == 1) try ju.strVal(gpa, "stop") else .null;
    return acc;
}

test "dispatch modes" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init(gpa);
    defer bus.deinit();

    var state = testBusCtx{};
    const h = Handler{ .plugin_id = "p1", .priority = 1, .ctx = &state, .call = testHandler };
    try bus.register("emit", h);
    try bus.register("waterfall", h);
    try bus.register("bail", h);
    try std.testing.expectEqual(@as(usize, 1), bus.count("emit"));

    const r = try bus.dispatch("emit", .null, .emit);
    try std.testing.expect(r == .null);
    try std.testing.expectEqual(@as(usize, 1), state.seen);

    const acc = try bus.dispatch("waterfall", .null, .waterfall);
    try std.testing.expect(acc == .null);
    try std.testing.expectEqual(@as(usize, 2), state.seen);

    state.seen = 0;
    const b = try bus.dispatch("bail", .null, .bail);
    defer ju.freeJsonValue(gpa, b);
    try std.testing.expectEqualStrings("stop", b.string);
    try std.testing.expectEqual(@as(usize, 1), state.seen);

    try std.testing.expect(bus.unregister("emit", "p1"));
    try std.testing.expectEqual(@as(usize, 0), bus.count("emit"));
}

test "event log jsonl" {
    const gpa = std.testing.allocator;
    const path = "zig-cache/test-events.jsonl";
    var log = EventLog.init(gpa, path);
    const payload = try ju.parseValue(gpa, "{\"tool\":\"pcb_read\"}");
    defer ju.freeJsonValue(gpa, payload);
    const ev = Event{ .kind = "tool.execute", .ts_unix = 1700000000, .payload = payload };
    try log.append(ev);
    const raw = try log.readAll();
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"tool.execute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"tool\":\"pcb_read\"") != null);
}
