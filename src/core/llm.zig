//! LLM 客户端（纯 Zig，无第三方依赖）：OpenAI 兼容与 Anthropic 兼容，
//! 支持非流式与 SSE 流式。控制平面完全在 Zig 内实现。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("jsonutil.zig");

pub const copyJsonValue = ju.copyJsonValue;
pub const freeJsonValue = ju.freeJsonValue;
pub const objGet = ju.objGet;
pub const objStr = ju.objStr;
pub const objNum = ju.objNum;
pub const putKey = ju.putKey;
pub const strVal = ju.strVal;
pub const newArr = ju.newArr;
pub const newObj = ju.newObj;
pub const stringifyAlloc = ju.stringifyAlloc;

pub const Provider = enum { openai_compat, anthropic_compat };

pub fn providerFromString(s: []const u8) Provider {
    if (std.mem.eql(u8, s, "anthropic_compat")) return .anthropic_compat;
    return .openai_compat;
}

pub const Role = enum { system, user, assistant, tool };

pub fn roleTag(r: Role) []const u8 {
    return switch (r) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8,
    /// 模型生成的参数 JSON 文本。
    arguments: []const u8 = "{}",
};

pub const Message = struct {
    role: Role,
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    tool_call_id: []const u8 = "",
    reasoning: []const u8 = "",
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema（模型可见投影）。
    parameters: std.json.Value,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
};

pub const FinishReason = enum { stop, tool_calls, length, content_filter, failure, other };

pub fn freeCompletion(gpa: Allocator, c: Completion) void {
    gpa.free(c.content);
    gpa.free(c.reasoning);
    for (c.tool_calls) |tc| {
        gpa.free(tc.id);
        gpa.free(tc.name);
        gpa.free(tc.arguments);
    }
    gpa.free(c.tool_calls);
}

pub fn finishReasonFromString(s: []const u8) FinishReason {
    if (std.mem.eql(u8, s, "stop")) return .stop;
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, s, "length")) return .length;
    if (std.mem.eql(u8, s, "content_filter")) return .content_filter;
    return .other;
}

pub const Completion = struct {
    content: []const u8 = "",
    reasoning: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    finish_reason: FinishReason = .stop,
    usage: Usage = .{},
};

pub const Config = struct {
    provider: Provider = .openai_compat,
    api_base: []const u8 = "https://api.openai.com/v1",
    api_key: []const u8 = "",
    model: []const u8 = "",
    connect_timeout_ms: u64 = 30_000,
    read_timeout_ms: u64 = 120_000,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_tokens: ?u32 = null,
    extra_headers: []const std.http.Header = &.{},
};

pub const ClientError = error{
    BadUrl,
    UnsupportedUriScheme,
    HttpStatus,
    EmptyResponse,
    MalformedJson,
    NoChoices,
    ReadTimeout,
    ConnectTimeout,
    ResponseTooLarge,
    MissingApiKey,
    MissingModel,
};

pub const StreamEvent = union(enum) {
    delta: []const u8,
    reasoning: []const u8,
    tool_call: ToolCall,
    done: Completion,
};

pub const StreamSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, ev: StreamEvent) void,
};

/// 纯逻辑截止时间：在读取间隙判断是否超时（可测试）。
pub const Deadline = struct {
    start_ms: i64,
    timeout_ms: u64,

    pub fn init(timeout_ms: u64) Deadline {
        return .{ .start_ms = std.time.milliTimestamp(), .timeout_ms = timeout_ms };
    }

    pub fn elapsedMs(self: Deadline) i64 {
        return std.time.milliTimestamp() - self.start_ms;
    }

    pub fn exceeded(self: Deadline) bool {
        if (self.timeout_ms == 0) return false;
        return self.elapsedMs() > @as(i64, @intCast(self.timeout_ms));
    }

    pub fn remainingMs(self: Deadline) u64 {
        if (self.timeout_ms == 0) return std.math.maxInt(u64);
        const used = self.elapsedMs();
        if (used < 0) return self.timeout_ms;
        const t: i64 = @intCast(self.timeout_ms);
        if (used >= t) return 0;
        return @intCast(t - used);
    }
};

// ---------------------------------------------------------------------------
// JSON 值辅助
// ---------------------------------------------------------------------------

fn parseArgValue(gpa: Allocator, arguments: []const u8) std.json.Value {
    if (arguments.len == 0) return .null;
    if (std.json.parseFromSlice(std.json.Value, gpa, arguments, .{})) |p| {
        defer p.deinit();
        return ju.copyJsonValue(gpa, p.value) catch .null;
    } else |_| {
        return .{ .string = gpa.dupe(u8, arguments) catch "" };
    }
}

// ---------------------------------------------------------------------------
// 响应解析
// ---------------------------------------------------------------------------

pub fn parseCompletion(gpa: Allocator, root_value: std.json.Value, provider: Provider) !Completion {
    const root = switch (root_value) {
        .object => |o| o,
        else => return error.MalformedJson,
    };
    switch (provider) {
        .openai_compat => return parseOpenAiCompletion(gpa, root),
        .anthropic_compat => return parseAnthropicCompletion(gpa, root),
    }
}

fn parseOpenAiCompletion(gpa: Allocator, root: std.json.ObjectMap) !Completion {
    const choices_v = ju.objGet(root, "choices") orelse return error.NoChoices;
    const choices = switch (choices_v) {
        .array => |a| a,
        else => return error.NoChoices,
    };
    if (choices.items.len == 0) return error.NoChoices;
    const choice = switch (choices.items[0]) {
        .object => |o| o,
        else => return error.NoChoices,
    };
    const msg_v = ju.objGet(choice, "message") orelse return error.NoChoices;
    const msg = switch (msg_v) {
        .object => |o| o,
        else => return error.NoChoices,
    };

    var out: Completion = .{};
    out.content = try gpa.dupe(u8, ju.objStr(msg, "content"));
    out.reasoning = try gpa.dupe(u8, ju.objStr(msg, "reasoning_content"));
    out.finish_reason = finishReasonFromString(ju.objStr(choice, "finish_reason"));

    if (ju.objGet(root, "usage")) |usage_v| {
        if (usage_v == .object) {
            const u = usage_v.object;
            out.usage.prompt_tokens = ju.objNum(u, "prompt_tokens");
            out.usage.completion_tokens = ju.objNum(u, "completion_tokens");
        }
    }

    if (ju.objGet(msg, "tool_calls")) |calls_v| {
        if (calls_v == .array) {
            var calls: std.ArrayList(ToolCall) = .empty;
            errdefer calls.deinit(gpa);
            for (calls_v.array.items) |cv| {
                if (cv != .object) continue;
                const call = cv.object;
                const fn_v = ju.objGet(call, "function") orelse continue;
                if (fn_v != .object) continue;
                const args = ju.objGet(fn_v.object, "arguments");
                var args_text: []const u8 = "";
                if (args) |a| {
                    args_text = switch (a) {
                        .string => try gpa.dupe(u8, a.string),
                        else => try ju.stringifyAlloc(gpa, a),
                    };
                }
                try calls.append(gpa, .{
                    .id = try gpa.dupe(u8, ju.objStr(call, "id")),
                    .name = try gpa.dupe(u8, ju.objStr(fn_v.object, "name")),
                    .arguments = args_text,
                });
            }
            out.tool_calls = try calls.toOwnedSlice(gpa);
        }
    }
    return out;
}

fn parseAnthropicCompletion(gpa: Allocator, root: std.json.ObjectMap) !Completion {
    var out: Completion = .{};
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(gpa);

    const blocks_v = ju.objGet(root, "content") orelse return error.NoChoices;
    if (blocks_v == .array) {
        for (blocks_v.array.items) |bv| {
            if (bv != .object) continue;
            const b = bv.object;
            const t = ju.objStr(b, "type");
            if (std.mem.eql(u8, t, "text")) {
                content.appendSlice(gpa, ju.objStr(b, "text")) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, t, "tool_use")) {
                const input = ju.objGet(b, "input");
                const args_text = if (input) |iv| try ju.stringifyAlloc(gpa, iv) else try gpa.dupe(u8, "{}");
                try calls.append(gpa, .{
                    .id = try gpa.dupe(u8, ju.objStr(b, "id")),
                    .name = try gpa.dupe(u8, ju.objStr(b, "name")),
                    .arguments = args_text,
                });
            }
        }
    }

    out.content = try content.toOwnedSlice(gpa);
    out.tool_calls = try calls.toOwnedSlice(gpa);
    const stop_reason = ju.objStr(root, "stop_reason");
    if (std.mem.eql(u8, stop_reason, "tool_use")) {
        out.finish_reason = .tool_calls;
    } else if (std.mem.eql(u8, stop_reason, "max_tokens")) {
        out.finish_reason = .length;
    } else if (stop_reason.len == 0) {
        out.finish_reason = .stop;
    } else {
        out.finish_reason = .other;
    }
    if (ju.objGet(root, "usage")) |usage_v| {
        if (usage_v == .object) {
            out.usage.prompt_tokens = ju.objNum(usage_v.object, "input_tokens");
            out.usage.completion_tokens = ju.objNum(usage_v.object, "output_tokens");
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// 流式状态
// ---------------------------------------------------------------------------

const AccumulatedCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.ArrayList(u8),
};

pub const StreamState = struct {
    provider: Provider,
    content: std.ArrayList(u8),
    reasoning: std.ArrayList(u8),
    calls: std.ArrayList(AccumulatedCall),
    buf: std.ArrayList(u8),

    pub fn init(provider: Provider) StreamState {
        return .{
            .provider = provider,
            .content = .empty,
            .reasoning = .empty,
            .calls = .empty,
            .buf = .empty,
        };
    }

    pub fn deinit(self: *StreamState, gpa: Allocator) void {
        self.content.deinit(gpa);
        self.reasoning.deinit(gpa);
        for (0..self.calls.items.len) |i| self.calls.items[i].arguments.deinit(gpa);
        self.calls.deinit(gpa);
        self.buf.deinit(gpa);
    }

    pub fn toCompletion(self: *StreamState, gpa: Allocator) Completion {
        var out: Completion = .{
            .content = gpa.dupe(u8, self.content.items) catch "",
            .reasoning = gpa.dupe(u8, self.reasoning.items) catch "",
        };
        var calls: std.ArrayList(ToolCall) = .empty;
        for (self.calls.items) |c| {
            calls.append(gpa, .{
                .id = gpa.dupe(u8, c.id) catch "",
                .name = gpa.dupe(u8, c.name) catch "",
                .arguments = gpa.dupe(u8, c.arguments.items) catch "{}",
            }) catch {};
        }
        out.tool_calls = calls.toOwnedSlice(gpa) catch &.{};
        out.finish_reason = if (out.tool_calls.len > 0) .tool_calls else .stop;
        return out;
    }

    fn callAt(self: *StreamState, gpa: Allocator, index: usize) !*AccumulatedCall {
        while (self.calls.items.len <= index) {
            try self.calls.append(gpa, .{
                .id = "",
                .name = "",
                .arguments = .empty,
            });
        }
        return &self.calls.items[index];
    }
};

var test_seen_buf: [256]u8 = undefined;
var test_seen_len: usize = 0;
fn testSinkEmit(ctx: *anyopaque, ev: StreamEvent) void {
    _ = ctx;
    switch (ev) {
        .delta => |t| {
            const n = @min(t.len, test_seen_buf.len - test_seen_len);
            @memcpy(test_seen_buf[test_seen_len .. test_seen_len + n], t[0..n]);
            test_seen_len += n;
        },
        .reasoning => |t| {
            const n = @min(t.len, test_seen_buf.len - test_seen_len);
            @memcpy(test_seen_buf[test_seen_len .. test_seen_len + n], t[0..n]);
            test_seen_len += n;
        },
        else => {},
    }
}
fn handleSseLine(gpa: Allocator, state: *StreamState, raw_line: []const u8, sink: StreamSink) !void {
    var line = raw_line;
    if (line.len > 0 and line[0] == ':') return;
    if (std.mem.startsWith(u8, line, "data:")) line = std.mem.trim(u8, line[5..], " \t\r");
    if (line.len == 0) return;
    if (std.mem.eql(u8, line, "[DONE]")) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    switch (state.provider) {
        .openai_compat => try handleOpenAiChunk(gpa, state, root, sink),
        .anthropic_compat => try handleAnthropicEvent(gpa, state, root, sink),
    }
}

fn handleOpenAiChunk(gpa: Allocator, state: *StreamState, root: std.json.ObjectMap, sink: StreamSink) !void {
    const choices_v = ju.objGet(root, "choices") orelse return;
    if (choices_v != .array or choices_v.array.items.len == 0) return;
    if (choices_v.array.items[0] != .object) return;
    const choice = choices_v.array.items[0].object;
    const delta_v = ju.objGet(choice, "delta") orelse return;
    if (delta_v != .object) return;
    const delta = delta_v.object;

    const text = ju.objStr(delta, "content");
    if (text.len > 0) {
        state.content.appendSlice(gpa, text) catch return error.OutOfMemory;
        sink.emit(sink.ctx, .{ .delta = text });
    }
    const think = ju.objStr(delta, "reasoning_content");
    if (think.len > 0) {
        state.reasoning.appendSlice(gpa, think) catch return error.OutOfMemory;
        sink.emit(sink.ctx, .{ .reasoning = think });
    }

    if (ju.objGet(delta, "tool_calls")) |calls_v| {
        if (calls_v != .array) return;
        for (calls_v.array.items, 0..) |cv, i| {
            if (cv != .object) continue;
            const call = cv.object;
            const acc = try state.callAt(gpa, i);
            if (ju.objStr(call, "id").len > 0) acc.id = gpa.dupe(u8, ju.objStr(call, "id")) catch acc.id;
            if (ju.objGet(call, "function")) |fv| {
                if (fv == .object) {
                    if (ju.objStr(fv.object, "name").len > 0) acc.name = gpa.dupe(u8, ju.objStr(fv.object, "name")) catch acc.name;
                    const args = ju.objGet(fv.object, "arguments");
                    if (args) |a| {
                        if (a == .string) acc.arguments.appendSlice(gpa, a.string) catch return error.OutOfMemory;
                    }
                }
            }
            if (acc.name.len > 0) {
                sink.emit(sink.ctx, .{ .tool_call = .{
                    .id = acc.id,
                    .name = acc.name,
                    .arguments = acc.arguments.items,
                } });
            }
        }
    }
}

fn handleAnthropicEvent(gpa: Allocator, state: *StreamState, root: std.json.ObjectMap, sink: StreamSink) !void {
    const ev_type = ju.objStr(root, "type");
    if (std.mem.eql(u8, ev_type, "content_block_delta")) {
        const delta_v = ju.objGet(root, "delta") orelse return;
        if (delta_v != .object) return;
        const delta = delta_v.object;
        const dt = ju.objStr(delta, "type");
        if (std.mem.eql(u8, dt, "text_delta")) {
            const text = ju.objStr(delta, "text");
            if (text.len > 0) {
                state.content.appendSlice(gpa, text) catch return error.OutOfMemory;
                sink.emit(sink.ctx, .{ .delta = text });
            }
        } else if (std.mem.eql(u8, dt, "thinking_delta")) {
            const think = ju.objStr(delta, "thinking");
            if (think.len > 0) {
                state.reasoning.appendSlice(gpa, think) catch return error.OutOfMemory;
                sink.emit(sink.ctx, .{ .reasoning = think });
            }
        }
        return;
    }
    if (std.mem.eql(u8, ev_type, "content_block_start")) {
        const block_v = ju.objGet(root, "content_block") orelse return;
        if (block_v != .object) return;
        const block = block_v.object;
        if (std.mem.eql(u8, ju.objStr(block, "type"), "tool_use")) {
            const acc = try state.callAt(gpa, ju.objNum(root, "index"));
            acc.id = gpa.dupe(u8, ju.objStr(block, "id")) catch acc.id;
            acc.name = gpa.dupe(u8, ju.objStr(block, "name")) catch acc.name;
        }
        return;
    }
    if (std.mem.eql(u8, ev_type, "message_stop")) return;
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

pub const Client = struct {
    gpa: Allocator,
    config: Config,

    pub fn init(gpa: Allocator, config: Config) Client {
        return .{ .gpa = gpa, .config = config };
    }

    pub fn endpoint(self: *const Client, gpa: Allocator) ![]const u8 {
        const base = self.config.api_base;
        if (base.len == 0) return error.BadUrl;
        var trimmed = base;
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        if (self.config.provider == .anthropic_compat) {
            if (std.mem.endsWith(u8, trimmed, "/v1")) return try std.fmt.allocPrint(gpa, "{s}/messages", .{trimmed});
            return try std.fmt.allocPrint(gpa, "{s}/v1/messages", .{trimmed});
        }
        if (std.mem.endsWith(u8, trimmed, "/chat/completions")) return try gpa.dupe(u8, trimmed);
        return try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimmed});
    }

    pub fn headerList(self: *const Client, gpa: Allocator) ![]const std.http.Header {
        var list: std.ArrayList(std.http.Header) = .empty;
        errdefer {
            for (list.items) |h| gpa.free(h.value);
            list.deinit(gpa);
        }
        try list.append(gpa, .{ .name = "content-type", .value = try gpa.dupe(u8, "application/json") });
        if (self.config.api_key.len > 0) {
            if (self.config.provider == .anthropic_compat) {
                try list.append(gpa, .{ .name = "x-api-key", .value = try gpa.dupe(u8, self.config.api_key) });
                try list.append(gpa, .{ .name = "anthropic-version", .value = try gpa.dupe(u8, "2023-06-01") });
            } else {
                const v = try std.fmt.allocPrint(gpa, "Bearer {s}", .{self.config.api_key});
                errdefer gpa.free(v);
                try list.append(gpa, .{ .name = "authorization", .value = v });
            }
        }
        for (self.config.extra_headers) |h| {
            try list.append(gpa, .{ .name = h.name, .value = try gpa.dupe(u8, h.value) });
        }
        return try list.toOwnedSlice(gpa);
    }

    /// `headerList` 返回的头由调用方持有：值需要逐个释放后再释放列表本身。
    pub fn freeHeaderList(gpa: Allocator, headers: []const std.http.Header) void {
        for (headers) |h| gpa.free(h.value);
        gpa.free(headers);
    }

    pub fn buildRequest(
        self: *const Client,
        gpa: Allocator,
        messages: []const Message,
        tools: []const ToolDef,
        stream: bool,
    ) !std.json.Value {
        if (self.config.model.len == 0) return error.MissingModel;
        switch (self.config.provider) {
            .openai_compat => return Client.buildOpenAiRequest(self, gpa, messages, tools, stream),
            .anthropic_compat => return Client.buildAnthropicRequest(self, gpa, messages, tools, stream),
        }
    }

    fn buildOpenAiRequest(self: *const Client, gpa: Allocator, messages: []const Message, tools: []const ToolDef, stream: bool) !std.json.Value {
        var root = std.json.ObjectMap.init(gpa);
        errdefer root.deinit();
        try ju.putKey(gpa, &root, "model", try ju.strVal(gpa, self.config.model));
        if (stream) try ju.putKey(gpa, &root, "stream", .{ .bool = true });

        var arr = ju.newArr(gpa);
        for (messages) |m| {
            var obj = ju.newObj(gpa);
            try ju.putKey(gpa, &obj.object, "role", try ju.strVal(gpa, roleTag(m.role)));
            if (m.role == .assistant and m.content.len == 0) {
                try ju.putKey(gpa, &obj.object, "content", .null);
            } else {
                try ju.putKey(gpa, &obj.object, "content", try ju.strVal(gpa, m.content));
            }
            if (m.role == .tool) try ju.putKey(gpa, &obj.object, "tool_call_id", try ju.strVal(gpa, m.tool_call_id));
            if (m.tool_calls.len > 0) {
                var calls = ju.newArr(gpa);
                for (m.tool_calls) |tc| {
                    var call = ju.newObj(gpa);
                    try ju.putKey(gpa, &call.object, "id", try ju.strVal(gpa, tc.id));
                    try ju.putKey(gpa, &call.object, "type", try ju.strVal(gpa, "function"));
                    var fnobj = ju.newObj(gpa);
                    try ju.putKey(gpa, &fnobj.object, "name", try ju.strVal(gpa, tc.name));
                    try ju.putKey(gpa, &fnobj.object, "arguments", parseArgValue(gpa, tc.arguments));
                    try ju.putKey(gpa, &call.object, "function", fnobj);
                    try calls.array.append(call);
                }
                try ju.putKey(gpa, &obj.object, "tool_calls", calls);
            }
            try arr.array.append(obj);
        }
        try ju.putKey(gpa, &root, "messages", arr);

        if (tools.len > 0) {
            var tarr = ju.newArr(gpa);
            for (tools) |t| {
                var tobj = ju.newObj(gpa);
                try ju.putKey(gpa, &tobj.object, "type", try ju.strVal(gpa, "function"));
                var f = ju.newObj(gpa);
                try ju.putKey(gpa, &f.object, "name", try ju.strVal(gpa, t.name));
                try ju.putKey(gpa, &f.object, "description", try ju.strVal(gpa, t.description));
                try ju.putKey(gpa, &f.object, "parameters", try ju.copyJsonValue(gpa, t.parameters));
                try ju.putKey(gpa, &tobj.object, "function", f);
                try tarr.array.append(tobj);
            }
            try ju.putKey(gpa, &root, "tools", tarr);
        }

        if (self.config.temperature) |v| try ju.putKey(gpa, &root, "temperature", .{ .float = v });
        if (self.config.top_p) |v| try ju.putKey(gpa, &root, "top_p", .{ .float = v });
        if (self.config.max_tokens) |v| try ju.putKey(gpa, &root, "max_tokens", .{ .integer = @intCast(v) });
        return .{ .object = root };
    }

    fn buildAnthropicRequest(self: *const Client, gpa: Allocator, messages: []const Message, tools: []const ToolDef, stream: bool) !std.json.Value {
        var root = std.json.ObjectMap.init(gpa);
        errdefer root.deinit();
        try ju.putKey(gpa, &root, "model", try ju.strVal(gpa, self.config.model));
        try ju.putKey(gpa, &root, "max_tokens", .{ .integer = @intCast(self.config.max_tokens orelse 1024) });
        if (stream) try ju.putKey(gpa, &root, "stream", .{ .bool = true });

        var system_text: std.ArrayList(u8) = .empty;
        defer system_text.deinit(gpa);
        var arr = ju.newArr(gpa);

        for (messages) |m| {
            if (m.role == .system) {
                if (system_text.items.len > 0) try system_text.append(gpa, '\n');
                try system_text.appendSlice(gpa, m.content);
                continue;
            }
            var obj = ju.newObj(gpa);
            try ju.putKey(gpa, &obj.object, "role", try ju.strVal(gpa, roleTag(m.role)));
            var blocks = ju.newArr(gpa);
            if (m.content.len > 0) {
                var b = ju.newObj(gpa);
                try ju.putKey(gpa, &b.object, "type", try ju.strVal(gpa, "text"));
                try ju.putKey(gpa, &b.object, "text", try ju.strVal(gpa, m.content));
                try blocks.array.append(b);
            }
            for (m.tool_calls) |tc| {
                var b = ju.newObj(gpa);
                try ju.putKey(gpa, &b.object, "type", try ju.strVal(gpa, "tool_use"));
                try ju.putKey(gpa, &b.object, "id", try ju.strVal(gpa, tc.id));
                try ju.putKey(gpa, &b.object, "name", try ju.strVal(gpa, tc.name));
                try ju.putKey(gpa, &b.object, "input", parseArgValue(gpa, tc.arguments));
                try blocks.array.append(b);
            }
            if (m.role == .tool) {
                var b = ju.newObj(gpa);
                try ju.putKey(gpa, &b.object, "type", try ju.strVal(gpa, "tool_result"));
                try ju.putKey(gpa, &b.object, "tool_use_id", try ju.strVal(gpa, m.tool_call_id));
                try ju.putKey(gpa, &b.object, "content", try ju.strVal(gpa, m.content));
                try blocks.array.append(b);
            }
            try ju.putKey(gpa, &obj.object, "content", blocks);
            try arr.array.append(obj);
        }

        if (system_text.items.len > 0) try ju.putKey(gpa, &root, "system", try ju.strVal(gpa, system_text.items));
        try ju.putKey(gpa, &root, "messages", arr);

        if (tools.len > 0) {
            var tarr = ju.newArr(gpa);
            for (tools) |t| {
                var tobj = ju.newObj(gpa);
                try ju.putKey(gpa, &tobj.object, "name", try ju.strVal(gpa, t.name));
                try ju.putKey(gpa, &tobj.object, "description", try ju.strVal(gpa, t.description));
                try ju.putKey(gpa, &tobj.object, "input_schema", try ju.copyJsonValue(gpa, t.parameters));
                try tarr.array.append(tobj);
            }
            try ju.putKey(gpa, &root, "tools", tarr);
        }
        return .{ .object = root };
    }

    pub fn complete(self: *Client, messages: []const Message, tools: []const ToolDef) !Completion {
        const gpa = self.gpa;
        if (self.config.api_key.len == 0) return error.MissingApiKey;

        const hdrs = try self.headerList(gpa);
        defer freeHeaderList(gpa, hdrs);

        const req_json = try self.buildRequest(gpa, messages, tools, false);
        const body = try std.json.Stringify.valueAlloc(gpa, req_json, .{});
        defer ju.freeJsonValue(gpa, req_json);
        defer gpa.free(body);

        const url = try self.endpoint(gpa);
        defer gpa.free(url);

        var client = std.http.Client{ .allocator = gpa, .read_buffer_size = 65536 };
        defer client.deinit();

        var out = std.Io.Writer.Allocating.init(gpa);
        defer out.deinit();

        const deadline = Deadline.init(self.config.read_timeout_ms);
        const res = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = hdrs,
            .response_writer = &out.writer,
        });
        const status = @intFromEnum(res.status);
        if (status < 200 or status >= 300) return error.HttpStatus;
        if (out.written().len == 0) return error.EmptyResponse;
        if (deadline.exceeded()) return error.ReadTimeout;

        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
        defer parsed.deinit();
        return parseCompletion(gpa, parsed.value, self.config.provider);
    }

    pub fn completeStream(self: *Client, messages: []const Message, tools: []const ToolDef, sink: StreamSink) !Completion {
        const gpa = self.gpa;
        if (self.config.api_key.len == 0) return error.MissingApiKey;

        const hdrs = try self.headerList(gpa);
        defer freeHeaderList(gpa, hdrs);

        const req_json = try self.buildRequest(gpa, messages, tools, true);
        const body = try std.json.Stringify.valueAlloc(gpa, req_json, .{});
        defer ju.freeJsonValue(gpa, req_json);
        defer gpa.free(body);

        const url = try self.endpoint(gpa);
        defer gpa.free(url);

        var client = std.http.Client{ .allocator = gpa, .read_buffer_size = 65536 };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var req = try client.request(.POST, uri, .{ .extra_headers = hdrs, .keep_alive = false });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        var redirect_buf: [4096]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);
        const status = @intFromEnum(resp.head.status);
        if (status < 200 or status >= 300) return error.HttpStatus;

        var transfer_buf: [8192]u8 = undefined;
        const reader = resp.reader(&transfer_buf);

        var state = StreamState.init(self.config.provider);
        defer state.deinit(gpa);

        var chunk: [4096]u8 = undefined;
        const deadline = Deadline.init(self.config.read_timeout_ms);
        while (true) {
            if (deadline.exceeded()) return error.ReadTimeout;
            const n = reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try consumeSse(gpa, &state, chunk[0..n], sink);
        }
        return state.toCompletion(gpa);
    }
};

// 逐行消费 SSE：处理完一行后把剩余字节前移，保证下一次从行首开始扫描。
pub fn consumeSse(gpa: Allocator, state: *StreamState, bytes: []const u8, sink: StreamSink) !void {
    try state.buf.appendSlice(gpa, bytes);
    while (true) {
        const nl = std.mem.indexOfScalar(u8, state.buf.items, '\n') orelse break;
        const line = state.buf.items[0..nl];
        try handleSseLine(gpa, state, line, sink);
        const rest = state.buf.items[nl + 1 ..];
        std.mem.copyForwards(u8, state.buf.items[0..rest.len], rest);
        state.buf.shrinkRetainingCapacity(rest.len);
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "endpoint shapes" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var c = Client.init(gpa, .{ .api_base = "http://example.com/v1", .model = "m" });
    const u = try c.endpoint(gpa);
    defer gpa.free(u);
    try std.testing.expectEqualStrings("http://example.com/v1/chat/completions", u);

    c.config.provider = .anthropic_compat;
    const u_b = try c.endpoint(gpa);
    defer gpa.free(u_b);
    try std.testing.expectEqualStrings("http://example.com/v1/messages", u_b);
}

test "openai request body" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const c = Client.init(gpa, .{ .api_base = "http://x/v1", .model = "m1" });
    const msgs = [_]Message{
        .{ .role = .system, .content = "hi" },
        .{ .role = .user, .content = "2+2?" },
    };
    const schema = std.json.parseFromSlice(std.json.Value, gpa, "{\"type\":\"object\",\"properties\":{}}", .{}) catch return error.SkipZigTest;
    defer schema.deinit();
    const tools = [_]ToolDef{.{ .name = "calc", .description = "d", .parameters = schema.value }};

    const req = try c.buildRequest(gpa, &msgs, &tools, false);
    const text = try std.json.Stringify.valueAlloc(gpa, req, .{});
    defer gpa.free(text);
    defer ju.freeJsonValue(gpa, req);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"model\":\"m1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"tools\"") != null);
}

test "openai completion parse" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const raw = "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"function\":{\"name\":\"calc\",\"arguments\":\"{\\\"expr\\\":\\\"2+2\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const c = try parseCompletion(gpa, parsed.value, .openai_compat);
    defer freeCompletion(gpa, c);
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.len);
    try std.testing.expectEqualStrings("calc", c.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"expr\":\"2+2\"}", c.tool_calls[0].arguments);
    try std.testing.expectEqualStrings("c1", c.tool_calls[0].id);
    try std.testing.expectEqual(@as(u64, 3), c.usage.prompt_tokens);
    try std.testing.expectEqual(FinishReason.tool_calls, c.finish_reason);
}

test "anthropic completion parse" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const raw = "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"f\",\"input\":{\"a\":1}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":2,\"output_tokens\":5}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const c = try parseCompletion(gpa, parsed.value, .anthropic_compat);
    defer freeCompletion(gpa, c);
    try std.testing.expectEqualStrings("hello", c.content);
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.len);
    try std.testing.expectEqualStrings("tu1", c.tool_calls[0].id);
    try std.testing.expectEqual(@as(u64, 5), c.usage.completion_tokens);
}

test "sse line accumulation" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var state = StreamState.init(.openai_compat);
    defer state.deinit(gpa);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);

    const sink = StreamSink{ .ctx = &seen, .emit = testSinkEmit };

    try handleSseLine(gpa, &state, "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}", sink);
    try handleSseLine(gpa, &state, "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}", sink);
    try std.testing.expectEqualStrings("Hello", test_seen_buf[0..test_seen_len]);
    try std.testing.expectEqualStrings("Hello", state.content.items);
}

test "deadline logic" {
    const d = Deadline.init(50);
    try std.testing.expect(!d.exceeded());
    try std.testing.expect(d.remainingMs() > 0);
    const zero = Deadline.init(0);
    try std.testing.expect(!zero.exceeded());
}

test "consumeSse 按行切分并派发事件" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var state = StreamState.init(.openai_compat);
    defer state.deinit(gpa);
    test_seen_len = 0;

    var dummy: u8 = 0;
    const sink = StreamSink{ .ctx = &dummy, .emit = testSinkEmit };
    const payload = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++ ": keep-alive\n\n" ++ "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" ++ "data: [DONE]\n\n";
    try consumeSse(gpa, &state, payload, sink);
    try std.testing.expectEqualStrings("Hello", test_seen_buf[0..test_seen_len]);
    try std.testing.expectEqualStrings("Hello", state.content.items);
}
test "headerList 的值归调用方持有" {
    const gpa = std.testing.allocator;
    var client = Client.init(gpa, .{ .api_key = "k", .model = "m" });

    const headers = try client.headerList(gpa);
    // 必须逐个释放值再释放列表：只 free 列表会泄漏每个头的值。
    for (headers) |h| gpa.free(h.value);
    gpa.free(headers);

    const again = try client.headerList(gpa);
    defer Client.freeHeaderList(gpa, again);
    try std.testing.expectEqual(@as(usize, 2), again.len);
    try std.testing.expectEqualStrings("application/json", again[0].value);
    try std.testing.expectEqualStrings("Bearer k", again[1].value);
}
