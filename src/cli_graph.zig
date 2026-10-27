//! CLI 图命令：技能目录 / 构图 / 执行 / 硬门评估 / 检查点续跑。
//! 全部通过统一工具注册表执行，与 Agent 和插件共用同一入口与权限检查。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("core/jsonutil.zig");
const cli = @import("cli_common.zig");
const host = @import("host.zig");
const cli_common = @import("cli_common.zig");
const ioc = @import("ioctx");

pub const Options = struct {
    max_rounds: usize = 12,
    plugins: []const []const u8 = &.{},
};

pub fn run(gpa: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, argv: []const []const u8, opts: Options) !void {
    if (argv.len < 3) {
        try err.print("用法: graph skills | plan <skill> [--input JSON] | run <skill> [project] [--input JSON] [--max-iterations N] [--measurements JSON] [--resume] | gate --measurements JSON [--skill SKILL] | checkpoint <skill>\n检查点目录：--checkpoint-dir PATH 或 CUTECLAW_CHECKPOINT_DIR（跨进程续跑时从磁盘读回执行记录）\n（图技能目录来自 GitHub 上真实 PCB / CAD / 包装工程 skill；执行前必须先通过对抗性审查）\n", .{});
        cli_common.exit(out, err, 2);
    }
    const sub = argv[2];

    const h = try cli.buildHost(gpa, argv, .{ .max_rounds = opts.max_rounds, .plugins = opts.plugins }, err);
    defer h.free();
    var app = h.app();
    defer app.deinit();

    // 检查点目录：续跑通常发生在另一个进程里，执行记录必须能落盘再读回。
    var checkpoint_dir: ?[]const u8 = null;
    if (cli.flagValue(argv, "--checkpoint-dir")) |dir| {
        checkpoint_dir = try gpa.dupe(u8, dir);
    } else if (ioc.envOwned(gpa, "CUTECLAW_CHECKPOINT_DIR")) |dir| {
        checkpoint_dir = dir;
    } else |_| {}
    if (checkpoint_dir) |dir| h.graph.checkpoint_dir = dir;
    defer if (checkpoint_dir) |dir| gpa.free(dir);

    const args = try buildArgs(gpa, argv, sub);
    defer ju.freeJsonValue(gpa, args);

    const result = app.callTool(subToolName(sub), args) catch |e| {
        try err.print("图工具失败: {s}\n", .{@errorName(e)});
        try err.flush();
        cli_common.exit(out, err, 1);
    };
    defer ju.freeJsonValue(gpa, result);

    try out.print("{s}\n", .{ju.objStr(result.object, "content")});
    try out.flush();
}

fn subToolName(sub: []const u8) []const u8 {
    if (std.mem.eql(u8, sub, "skills")) return "graph_skills";
    if (std.mem.eql(u8, sub, "plan")) return "graph_plan";
    if (std.mem.eql(u8, sub, "run")) return "graph_run";
    if (std.mem.eql(u8, sub, "gate")) return "graph_gate";
    if (std.mem.eql(u8, sub, "checkpoint")) return "graph_checkpoint";
    return sub;
}

/// 把命令行参数映射成工具入参 JSON。
pub fn buildArgs(gpa: Allocator, argv: []const []const u8, sub: []const u8) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);

    if (std.mem.eql(u8, sub, "skills")) return obj;

    if (argv.len >= 4) try ju.putKey(gpa, &obj.object, "skill", try ju.strVal(gpa, argv[3]));

    if (std.mem.eql(u8, sub, "run") and argv.len >= 5) {
        try ju.putKey(gpa, &obj.object, "project", try ju.strVal(gpa, argv[4]));
    }

    if (cli.hasFlag(argv, "--resume")) try ju.putKey(gpa, &obj.object, "resume", .{ .bool = true });

    if (cli.flagValue(argv, "--input")) |text| {
        const parsed = try ju.parseValue(gpa, text);
        defer ju.freeJsonValue(gpa, parsed);
        try ju.putKey(gpa, &obj.object, "input", try ju.copyJsonValue(gpa, parsed));
    }

    if (cli.flagValue(argv, "--measurements")) |text| {
        const parsed = try ju.parseValue(gpa, text);
        defer ju.freeJsonValue(gpa, parsed);
        try ju.putKey(gpa, &obj.object, "measurements", try ju.copyJsonValue(gpa, parsed));
    }

    if (cli.flagValue(argv, "--max-iterations")) |text| {
        const limit = try std.fmt.parseInt(usize, text, 10);
        try ju.putKey(gpa, &obj.object, "max_iterations", .{ .integer = @intCast(limit) });
    }

    return obj;
}

test "graph cli maps subcommands to tools" {
    const gpa = std.testing.allocator;

    try std.testing.expectEqualStrings("graph_plan", subToolName("plan"));
    try std.testing.expectEqualStrings("graph_run", subToolName("run"));
    try std.testing.expectEqualStrings("graph_gate", subToolName("gate"));
    try std.testing.expectEqualStrings("graph_checkpoint", subToolName("checkpoint"));

    const argv = [_][]const u8{ "cuteclaw", "graph", "run", "pcb-design-review", "demo", "--max-iterations", "2", "--measurements", "[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"demo\",\"measured\":true}]" };
    const args = try buildArgs(gpa, &argv, "run");
    defer ju.freeJsonValue(gpa, args);

    try std.testing.expectEqualStrings("pcb-design-review", ju.objStr(args.object, "skill"));
    try std.testing.expectEqualStrings("demo", ju.objStr(args.object, "project"));
    try std.testing.expectEqual(@as(i64, 2), args.object.get("max_iterations").?.integer);
    try std.testing.expectEqual(@as(usize, 1), args.object.get("measurements").?.array.items.len);
}

test "graph cli runs a skill through the tool registry" {
    const gpa = std.testing.allocator;
    const h = try host.Host.init(gpa, .{ .model = "m" }, .{});
    defer h.free();
    var app = h.app();
    defer app.deinit();

    const args = try buildArgs(gpa, &[_][]const u8{ "cuteclaw", "graph", "plan", "pcb-design-review" }, "plan");
    defer ju.freeJsonValue(gpa, args);

    const result = try app.callTool("graph_plan", args);
    defer ju.freeJsonValue(gpa, result);

    const content = try ju.parseValue(gpa, ju.objStr(result.object, "content"));
    defer ju.freeJsonValue(gpa, content);

    try std.testing.expectEqualStrings("pcb-design-review", ju.objStr(content.object, "skill"));
    try std.testing.expect(content.object.get("layers") != null);
    try std.testing.expect(content.object.get("shape") != null);
}
