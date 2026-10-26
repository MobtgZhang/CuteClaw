//! 会话：消息链与 JSON 序列化（供 HTTP / WebSocket / 持久化复用）；令牌上限由 LLM 配置的 max_tokens 控制。

const std = @import("std");
const ju = @import("jsonutil.zig");
const llm = @import("llm.zig");

const Allocator = std.mem.Allocator;

pub const Session = struct {
    gpa: Allocator,
    id: []const u8,
    model: []const u8,
    system_prompt: []const u8,
    messages: std.ArrayList(llm.Message),

    pub fn init(gpa: Allocator, id: []const u8, model: []const u8, system_prompt: []const u8) Session {
        return .{
            .gpa = gpa,
            .id = id,
            .model = model,
            .system_prompt = system_prompt,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.messages.items) |m| {
            self.gpa.free(m.content);
            self.gpa.free(m.reasoning);
            self.gpa.free(m.tool_call_id);
            for (m.tool_calls) |tc| {
                self.gpa.free(tc.id);
                self.gpa.free(tc.name);
                self.gpa.free(tc.arguments);
            }
            self.gpa.free(m.tool_calls);
        }
        self.messages.deinit(self.gpa);
    }

    /// 会话持有自己的深拷贝：tool_calls 仅浅拷贝会让调用方与 Session 双重释放。
    pub fn append(self: *Session, m: llm.Message) !void {
        var calls: std.ArrayList(llm.ToolCall) = .empty;
        errdefer {
            for (calls.items) |tc| {
                self.gpa.free(tc.id);
                self.gpa.free(tc.name);
                self.gpa.free(tc.arguments);
            }
            calls.deinit(self.gpa);
        }
        for (m.tool_calls) |tc| {
            try calls.append(self.gpa, .{
                .id = try self.gpa.dupe(u8, tc.id),
                .name = try self.gpa.dupe(u8, tc.name),
                .arguments = try self.gpa.dupe(u8, tc.arguments),
            });
        }

        var copy: llm.Message = .{ .role = m.role };
        errdefer {
            self.gpa.free(copy.content);
            self.gpa.free(copy.reasoning);
            self.gpa.free(copy.tool_call_id);
            for (copy.tool_calls) |tc| {
                self.gpa.free(tc.id);
                self.gpa.free(tc.name);
                self.gpa.free(tc.arguments);
            }
            self.gpa.free(copy.tool_calls);
        }
        copy.content = try self.gpa.dupe(u8, m.content);
        copy.reasoning = try self.gpa.dupe(u8, m.reasoning);
        copy.tool_call_id = try self.gpa.dupe(u8, m.tool_call_id);
        copy.tool_calls = try calls.toOwnedSlice(self.gpa);
        try self.messages.append(self.gpa, copy);
    }

    /// 含 system 提示词的完整消息链（调用方负责释放切片与各元素）。
    pub fn prompt(self: *Session) ![]llm.Message {
        var out: std.ArrayList(llm.Message) = .empty;
        errdefer out.deinit(self.gpa);
        if (self.system_prompt.len > 0) {
            try out.append(self.gpa, .{ .role = .system, .content = self.system_prompt });
        }
        for (self.messages.items) |m| try out.append(self.gpa, m);
        return out.toOwnedSlice(self.gpa);
    }

    pub fn freePrompt(gpa: Allocator, items: []llm.Message) void {
        gpa.free(items);
    }

    pub fn toJson(self: *Session) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "id", try ju.strVal(self.gpa, self.id));
        try ju.putKey(self.gpa, &obj.object, "model", try ju.strVal(self.gpa, self.model));
        try ju.putKey(self.gpa, &obj.object, "system_prompt", try ju.strVal(self.gpa, self.system_prompt));
        var arr = ju.newArr(self.gpa);
        for (self.messages.items) |m| {
            var msg = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &msg.object, "role", try ju.strVal(self.gpa, llm.roleTag(m.role)));
            try ju.putKey(self.gpa, &msg.object, "content", try ju.strVal(self.gpa, m.content));
            if (m.tool_calls.len > 0) {
                var calls = ju.newArr(self.gpa);
                for (m.tool_calls) |tc| {
                    var call = ju.newObj(self.gpa);
                    try ju.putKey(self.gpa, &call.object, "id", try ju.strVal(self.gpa, tc.id));
                    try ju.putKey(self.gpa, &call.object, "name", try ju.strVal(self.gpa, tc.name));
                    try ju.putKey(self.gpa, &call.object, "arguments", try ju.parseValue(self.gpa, tc.arguments));
                    try calls.array.append(call);
                }
                try ju.putKey(self.gpa, &msg.object, "tool_calls", calls);
            }
            try arr.array.append(msg);
        }
        try ju.putKey(self.gpa, &obj.object, "messages", arr);
        return obj;
    }
};

test "session append and json" {
    const gpa = std.testing.allocator;
    var s = Session.init(gpa, "s1", "m", "you are CuteClaw");
    defer s.deinit();

    try s.append(.{ .role = .user, .content = "hello" });
    try s.append(.{ .role = .assistant, .content = "hi" });
    try std.testing.expectEqual(@as(usize, 2), s.messages.items.len);

    const prompt = try s.prompt();
    defer Session.freePrompt(gpa, prompt);
    try std.testing.expectEqual(@as(usize, 3), prompt.len);
    try std.testing.expectEqual(llm.Role.system, prompt[0].role);

    const json = try s.toJson();
    defer ju.freeJsonValue(gpa, json);
    const text = try ju.stringifyAlloc(gpa, json);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"role\":\"user\"") != null);
}
test "session append deep-copies tool calls" {
    const gpa = std.testing.allocator;
    var s = Session.init(gpa, "s1", "m", "");
    defer s.deinit();

    const calls = try gpa.alloc(llm.ToolCall, 1);
    calls[0] = .{
        .id = try gpa.dupe(u8, "c1"),
        .name = try gpa.dupe(u8, "echo"),
        .arguments = try gpa.dupe(u8, "{\"text\":\"hi\"}"),
    };
    const msg: llm.Message = .{
        .role = .assistant,
        .content = try gpa.dupe(u8, "run tool"),
        .tool_calls = calls,
    };
    try s.append(msg);

    // 调用方释放自己的消息：会话必须仍持有独立副本，否则会造成双重释放。
    gpa.free(msg.content);
    for (calls) |tc| {
        gpa.free(tc.id);
        gpa.free(tc.name);
        gpa.free(tc.arguments);
    }
    gpa.free(calls);

    const kept = s.messages.items[0];
    try std.testing.expectEqualStrings("run tool", kept.content);
    try std.testing.expectEqualStrings("c1", kept.tool_calls[0].id);
    try std.testing.expectEqualStrings("echo", kept.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", kept.tool_calls[0].arguments);
}
