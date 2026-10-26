//! CLI 插件命令：列出 / 加载 / 启停 DeepSeek Harness（Cordis）兼容插件，
//! 并通过受控桥接进程调用插件工具。控制平面仍在 Zig。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("core/jsonutil.zig");
const cli = @import("cli_common.zig");
const host = @import("host.zig");
const dsh = @import("plugins/dsh_bridge.zig");
const cli_common = @import("cli_common.zig");

pub const Options = struct {
    node_bin: []const u8 = "node",
    bridge_path: []const u8 = "bridges/deepseek-harness/bridge.mjs",
    max_rounds: usize = 12,
};

pub fn run(gpa: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, argv: []const []const u8, opts: Options) !void {
    if (argv.len < 3) {
        try err.print("用法: plugin list | load <package.json> | enable <id> | disable <id> | call <id> <tool> --args JSON\n", .{});
        cli_common.exit(out, err, 2);
    }
    const sub = argv[2];
    const plugins = try cli.flagValues(gpa, argv, "--plugin");
    defer {
        for (plugins) |p| gpa.free(p);
        gpa.free(plugins);
    }

    const h = try cli.buildHost(gpa, argv, .{ .max_rounds = opts.max_rounds, .plugins = plugins }, err);
    defer h.free();

    if (std.mem.eql(u8, sub, "list")) {
        try printPlugins(out, h);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, sub, "load")) {
        if (argv.len < 4) {
            try err.print("用法: plugin load <package.json>\n", .{});
            cli_common.exit(out, err, 2);
        }
        try h.loadPlugin(argv[3]);
        try printPlugins(out, h);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, sub, "enable") or std.mem.eql(u8, sub, "disable")) {
        if (argv.len < 4) {
            try err.print("用法: plugin enable|disable <id>\n", .{});
            cli_common.exit(out, err, 2);
        }
        const rec = h.kernel.find(argv[3]) orelse {
            try err.print("插件不存在: {s}\n", .{argv[3]});
            cli_common.exit(out, err, 1);
        };
        if (std.mem.eql(u8, sub, "enable")) try h.kernel.enable(rec.id) else try h.kernel.disable(rec.id);
        try out.print("{s} {s}\n", .{ rec.id, if (rec.enabled) "已启用" else "已停用" });
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, sub, "call")) {
        if (argv.len < 5) {
            try err.print("用法: plugin call <id> <tool> --args JSON\n", .{});
            cli_common.exit(out, err, 2);
        }
        const plugin_id = argv[3];
        const tool = argv[4];
        const args_text = cli.flagValue(argv, "--args") orelse "{}";
        const args = try ju.parseValue(gpa, args_text);
        defer ju.freeJsonValue(gpa, args);

        const rec = h.kernel.find(plugin_id);
        const root = if (rec) |r| r.root else ".";

        const inv = dsh.Invocation{
            .plugin_id = plugin_id,
            .plugin_root = root,
            .tool = tool,
            .args = args,
            .node_bin = opts.node_bin,
            .bridge_path = opts.bridge_path,
        };

        const result = dsh.run(gpa, inv) catch |e| {
            try err.print("桥接调用失败: {s}（需要 Node.js 与 {s}）\n", .{ @errorName(e), opts.bridge_path });
            try err.flush();
            cli_common.exit(out, err, 1);
        };
        defer result.free(gpa);

        const text = try ju.stringifyAlloc(gpa, result.meta);
        defer gpa.free(text);
        try out.print("{s}\n", .{result.content});
        // JSON-RPC 错误也是一条正常响应：把错误码原样打印，进程退出码保持 0。
        if (result.error_code != 0) try out.print("error: {d}\n", .{result.error_code});
        if (text.len > 0 and !std.mem.eql(u8, text, "null")) try out.print("meta: {s}\n", .{text});
        try out.flush();
        return;
    }

    try err.print("未知 plugin 子命令: {s}\n", .{sub});
    cli_common.exit(out, err, 2);
}

fn printPlugins(out: *std.Io.Writer, h: *host.Host) !void {
    if (h.kernel.plugins.items.len == 0) {
        try out.writeAll("(没有加载插件；使用 --plugin <package.json> 或 plugin load)\n");
        return;
    }
    for (h.kernel.plugins.items) |p| {
        try out.print("{s}\t{d}\t{s}\t{s}\n", .{
            p.id,
            p.manifest.manifest_version,
            if (p.enabled) "enabled" else "disabled",
            p.manifest.bundle,
        });
        if (p.manifest.capabilities.len > 0) {
            try out.print("  capabilities: ", .{});
            for (p.manifest.capabilities, 0..) |c, i| {
                if (i > 0) try out.writeAll(", ");
                try out.writeAll(c);
            }
            try out.writeAll("\n");
        }
    }
}

test "plugin cli parses args into a bridge invocation" {
    const gpa = std.testing.allocator;
    const argv = [_][]const u8{ "cuteclaw", "plugin", "call", "pcb-layout", "list", "--args", "{\"project\":\"demo\"}" };
    const args = try ju.parseValue(gpa, cli.flagValue(&argv, "--args").?);
    defer ju.freeJsonValue(gpa, args);

    const inv = dsh.Invocation{ .plugin_id = argv[3], .plugin_root = "skills/pcb-layout", .tool = argv[4], .args = args };
    const stdin_text = try dsh.buildStdin(gpa, inv);
    defer gpa.free(stdin_text);
    try std.testing.expect(std.mem.indexOf(u8, stdin_text, "\"tool\":\"list\"") != null);

    const env = try dsh.buildEnv(gpa, inv);
    defer dsh.freeEnv(gpa, env);
    try std.testing.expectEqualStrings("skills/pcb-layout", env[0].value);
}
