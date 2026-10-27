//! CLI 回路命令：计划 / 子代理派发 / 压缩 / 检查点 / 终止判定 / hook / 审批 / 技能文件。
//! 全部通过统一工具注册表执行，与 Agent 和插件共用同一入口与权限检查。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("core/jsonutil.zig");
const cli = @import("cli_common.zig");
const host = @import("host.zig");
const loop_tools = @import("loop/tools.zig");
const cli_common = @import("cli_common.zig");

pub const Options = struct {
    max_rounds: usize = 12,
    plugins: []const []const u8 = &.{},
};

const tool_names = std.StaticStringMap([]const u8).initComptime(.{
    .{ "plan", "loop_plan" },
    .{ "delegate", "loop_delegate" },
    .{ "compact", "loop_compact" },
    .{ "checkpoint", "loop_checkpoint" },
    .{ "stop-check", "loop_stop_check" },
    .{ "hooks", "loop_hooks" },
    .{ "approval", "loop_approval" },
    .{ "skills", "loop_skills" },
});

pub fn run(gpa: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, argv: []const []const u8, opts: Options) !void {
    if (argv.len < 3) {
        try err.print("用法: loop status | loop <plan|delegate|compact|checkpoint|stop-check|hooks|approval|skills> --input JSON\n（回路只接受可判定的终止条件；hook 只能收紧决策；不可逆动作一律停在人工审批门前）\n", .{});
        cli_common.exit(out, err, 2);
    }
    const sub = argv[2];

    const h = try cli.buildHost(gpa, argv, .{ .max_rounds = opts.max_rounds, .plugins = opts.plugins }, err);
    defer h.free();

    if (std.mem.eql(u8, sub, "status")) {
        try writeStatus(out, &h.loop);
        try out.flush();
        return;
    }

    const name = tool_names.get(sub) orelse {
        try err.print("未知回路命令: {s}\n", .{sub});
        cli_common.exit(out, err, 2);
    };

    const input_text = cli.flagValue(argv, "--input") orelse {
        try err.print("缺少 --input JSON\n", .{});
        cli_common.exit(out, err, 2);
    };

    var app = h.app();
    defer app.deinit();

    const args = try ju.parseValue(gpa, input_text);
    defer ju.freeJsonValue(gpa, args);

    const result = app.callTool(name, args) catch |e| {
        try err.print("回路工具失败: {s}\n", .{@errorName(e)});
        try err.flush();
        cli_common.exit(out, err, 1);
    };
    defer ju.freeJsonValue(gpa, result);

    try out.print("{s}\n", .{ju.objStr(result.object, "content")});
    try out.flush();
}

fn writeStatus(out: *std.Io.Writer, ws: *loop_tools.Workspace) !void {
    try out.print("loop workspace: {s}\n", .{ws.policy.workspace_root});
    try out.print("  plan: mode={s} goal={s} open={d} can_complete={s} budget={d} used={d}\n", .{
        @tagName(ws.plan.mode),
        ws.plan.goal,
        ws.plan.openCount(),
        if (ws.plan.canComplete()) "yes" else "no",
        ws.plan.budget_tokens,
        ws.plan.used_tokens,
    });
    try out.print("  hooks: {d} deny_patterns={d} ignored_grants={d}（hook 只能收紧决策）\n", .{
        ws.hooks.hooks.items.len,
        ws.hooks.deny_patterns.items.len,
        ws.hooks.ignored_grants,
    });
    try out.print("  approval: mode={s} rules={d} session_grants={d} refused_grants={d}（deny 优先于 allow 与会话级授权）\n", .{
        @tagName(ws.approval.mode),
        ws.approval.rules.items.len,
        ws.approval.session_grants.items.len,
        ws.approval.refused_grants,
    });
    try out.print("  compaction: budget={d} protected_last_n={d} items={d}\n", .{
        ws.compaction.budget_tokens,
        ws.compaction.protected_last_n,
        ws.items.items.len,
    });
    try out.print("  checkpoint: {d} 条记录（append-only，不可逆效果拒绝回退）\n", .{ws.recorder.records.items.len});
    try out.print("  learning: guardrail 前缀 {d} 项，不可被学习回路改写\n", .{ws.learning.guardrail_prefixes.len});
    try out.print("  skills dir: {s}\n", .{ws.skills_dir});
}

// --- 测试 ---

test "loop cli maps subcommands to tools" {
    try std.testing.expectEqualStrings("loop_plan", tool_names.get("plan").?);
    try std.testing.expectEqualStrings("loop_delegate", tool_names.get("delegate").?);
    try std.testing.expectEqualStrings("loop_compact", tool_names.get("compact").?);
    try std.testing.expectEqualStrings("loop_checkpoint", tool_names.get("checkpoint").?);
    try std.testing.expectEqualStrings("loop_stop_check", tool_names.get("stop-check").?);
    try std.testing.expectEqualStrings("loop_hooks", tool_names.get("hooks").?);
    try std.testing.expectEqualStrings("loop_approval", tool_names.get("approval").?);
    try std.testing.expectEqualStrings("loop_skills", tool_names.get("skills").?);
    try std.testing.expect(tool_names.get("status") == null);
}

test "loop cli runs the plan tool through the registry" {
    const gpa = std.testing.allocator;
    const h = try host.Host.init(gpa, .{ .model = "m" }, .{});
    defer h.free();
    var app = h.app();
    defer app.deinit();

    const argv = [_][]const u8{ "cuteclaw", "loop", "plan", "--input", "{\"goal\":\"enclosure fit\",\"mode\":\"plan\",\"tasks\":[{\"id\":\"t1\",\"title\":\"wall thickness\"}]}" };
    const args = try ju.parseValue(gpa, cli.flagValue(&argv, "--input").?);
    defer ju.freeJsonValue(gpa, args);

    const result = try app.callTool(tool_names.get("plan").?, args);
    defer ju.freeJsonValue(gpa, result);

    const content = try ju.parseValue(gpa, ju.objStr(result.object, "content"));
    defer ju.freeJsonValue(gpa, content);

    try std.testing.expectEqualStrings("plan", ju.objStr(content.object, "mode"));
    try std.testing.expect(!content.object.get("allows_write").?.bool);
    try std.testing.expectEqual(@as(i64, 1), content.object.get("open").?.integer);
}
