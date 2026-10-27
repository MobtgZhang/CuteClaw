//! DeepSeek Harness（Cordis）插件桥接：以独立受控进程运行插件，
//! 通过 stdin JSON + 环境变量（PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT）通信。
//! 控制平面仍在 Zig；桥接进程只是被调用的外部工具。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const ioc = @import("ioctx");

const Allocator = std.mem.Allocator;

pub const BridgeError = error{
    PluginFailed,
    InvalidOutput,
    OutOfMemory,
};

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const Invocation = struct {
    plugin_id: []const u8,
    plugin_root: []const u8,
    tool: []const u8,
    args: std.json.Value,
    node_bin: []const u8 = "node",
    bridge_path: []const u8 = "bridges/deepseek-harness/bridge.mjs",
};

pub const PluginOutput = struct {
    ok: bool,
    content: []const u8,
    meta: std.json.Value = .null,
    /// JSON-RPC 错误码（0 表示没有错误）：-32601 方法不存在、-32602 参数无效等。
    error_code: i64 = 0,

    pub fn free(self: *const PluginOutput, gpa: Allocator) void {
        gpa.free(self.content);
        ju.freeJsonValue(gpa, self.meta);
    }
};

/// 与 Cordis 插件运行时一致的最小环境变量集合。
pub fn buildEnv(gpa: Allocator, inv: Invocation) ![]EnvVar {
    var list: std.ArrayList(EnvVar) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.name);
            gpa.free(e.value);
        }
        list.deinit(
            gpa,
        );
    }
    const pairs = [_][2][]const u8{
        .{ "PLUGIN_ROOT", inv.plugin_root },
        .{ "CLAUDE_PLUGIN_ROOT", inv.plugin_root },
        .{ "CUTECLAW_PLUGIN_ID", inv.plugin_id },
        .{ "CUTECLAW_TOOL", inv.tool },
    };
    for (pairs) |p| try list.append(gpa, .{ .name = try gpa.dupe(u8, p[0]), .value = try gpa.dupe(u8, p[1]) });
    return list.toOwnedSlice(
        gpa,
    );
}

pub fn freeEnv(gpa: Allocator, env: []EnvVar) void {
    for (env) |e| {
        gpa.free(e.name);
        gpa.free(e.value);
    }
    gpa.free(env);
}

/// stdin 协议：{"plugin":id,"tool":name,"args":{...}}
pub fn buildStdin(gpa: Allocator, inv: Invocation) ![]const u8 {
    var obj = ju.newObj(gpa);
    defer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "plugin", try ju.strVal(gpa, inv.plugin_id));
    try ju.putKey(gpa, &obj.object, "tool", try ju.strVal(gpa, inv.tool));
    try ju.putKey(gpa, &obj.object, "args", try ju.copyJsonValue(gpa, inv.args));
    return ju.stringifyAlloc(gpa, obj);
}

pub fn parseOutput(gpa: Allocator, text: []const u8) !PluginOutput {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.InvalidOutput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOutput;
    const obj = parsed.value.object;
    var out: PluginOutput = .{
        .ok = false,
        .content = try gpa.dupe(u8, ju.objStr(obj, "content")),
    };
    errdefer out.free(gpa);
    if (ju.objGet(obj, "ok")) |ok_v| out.ok = ok_v == .bool and ok_v.bool;
    // JSON-RPC 错误码是负数，不能用无符号的 objNum。
    if (ju.objGet(obj, "error")) |err_v| {
        if (err_v == .object) {
            if (ju.objGet(err_v.object, "code")) |code_v| {
                switch (code_v) {
                    .integer => |i| out.error_code = i,
                    .float => |f| out.error_code = @intFromFloat(f),
                    else => {},
                }
            }
        }
    }
    out.meta = try ju.copyJsonValue(gpa, ju.objGet(obj, "meta") orelse .null);
    return out;
}

/// 运行桥接进程（外部工具），读取 stdout 的 JSON 结果。
pub fn run(gpa: Allocator, inv: Invocation) !PluginOutput {
    const env = try buildEnv(gpa, inv);
    defer freeEnv(gpa, env);

    const stdin_text = try buildStdin(gpa, inv);
    defer gpa.free(stdin_text);

    // 继承父进程环境（PATH 等），再叠加插件专用变量；否则 node 无法被解析。
    var env_map = try ioc.envTable().createMap(gpa);
    defer env_map.deinit();
    for (env) |e| try env_map.put(e.name, e.value);

    var child = try std.process.spawn(ioc.io(), .{
        .argv = &.{ inv.node_bin, inv.bridge_path },
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    if (child.stdin) |stdin_file| {
        const stdin = ioc.File.wrap(stdin_file);
        try stdin.writeAll(stdin_text);
        // 关闭后让 `wait()` 的 cleanupStreams 不再重复关闭同一个 fd。
        stdin.close();
        child.stdin = null;
    }
    const raw = try ioc.File.wrap(child.stdout.?).readToEndAlloc(gpa, 1024 * 1024);
    defer gpa.free(raw);

    const term = try child.wait(ioc.io());

    // 桥接把 JSON-RPC 错误写在 stdout 里：先解析响应，解析成功就按响应内容返回，
    // 只有拿不到响应时才把非零退出码当作进程级失败。
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const out = parseOutput(gpa, trimmed) catch |e| {
        if (e != error.InvalidOutput) return e;
        if (std.mem.eql(u8, @typeName(@TypeOf(term)), @typeName(std.process.Child.Term))) {
            switch (term) {
                .exited => |code| if (code != 0) return error.PluginFailed,
                else => return error.PluginFailed,
            }
        }
        return e;
    };
    if (!out.ok and out.content.len == 0 and out.error_code == 0) return error.PluginFailed;
    return out;
}

test "dsh bridge env and stdin protocol" {
    const gpa = std.testing.allocator;
    const args = try ju.parseValue(gpa, "{\"text\":\"hi\"}");
    defer ju.freeJsonValue(gpa, args);
    const inv = Invocation{ .plugin_id = "pcb-layout", .plugin_root = "skills/pcb-layout", .tool = "list", .args = args };

    const env = try buildEnv(gpa, inv);
    defer freeEnv(gpa, env);
    try std.testing.expectEqual(@as(usize, 4), env.len);
    try std.testing.expectEqualStrings("CLAUDE_PLUGIN_ROOT", env[1].name);
    try std.testing.expectEqualStrings("skills/pcb-layout", env[1].value);

    const stdin_text = try buildStdin(gpa, inv);
    defer gpa.free(stdin_text);
    try std.testing.expect(std.mem.indexOf(u8, stdin_text, "\"plugin\":\"pcb-layout\"") != null);

    const out = try parseOutput(gpa, "{\"ok\":true,\"content\":\"done\",\"meta\":{\"rows\":2}}");
    defer out.free(gpa);
    try std.testing.expect(out.ok);
    try std.testing.expectEqualStrings("done", out.content);
    try std.testing.expectEqual(@as(u64, 2), ju.objNum(out.meta.object, "rows"));
    try std.testing.expectError(error.InvalidOutput, parseOutput(gpa, "not json"));

    const err_out = try parseOutput(gpa, "{\"ok\":false,\"error\":{\"code\":-32601,\"message\":\"method not found\"},\"content\":\"method not found\",\"meta\":null}");
    defer err_out.free(gpa);
    try std.testing.expect(!err_out.ok);
    try std.testing.expectEqual(@as(i64, -32601), err_out.error_code);
}
