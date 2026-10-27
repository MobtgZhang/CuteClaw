//! CLI 设计命令：工程 / PCB 读取 / DRC / 外壳配合 / 候选排序。
//! 全部通过统一工具注册表执行，与 Agent 和插件共用同一入口与权限检查。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ju = @import("core/jsonutil.zig");
const cli = @import("cli_common.zig");
const host = @import("host.zig");
const http = @import("server/http.zig");
const cli_common = @import("cli_common.zig");
const ioc = @import("ioctx");

pub const Options = struct {
    max_rounds: usize = 12,
    plugins: []const []const u8 = &.{},
};

pub fn run(gpa: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, argv: []const []const u8, opts: Options) !void {
    if (argv.len < 3) {
        try err.print("用法: design open <id> [name] | constraint <project> <id> <kind> <limit> <方向> <级别> | read <project> --path FILE | drc <project> | fit <project> <宽> <高> <壁厚> | rank <project> --file FILE | skills\n（工作区仅存在于进程内：可用 --constraints JSON 先写入约束再执行目标工具）\n", .{});
        cli_common.exit(out, err, 2);
    }
    const sub = argv[2];

    const h = try cli.buildHost(gpa, argv, .{ .max_rounds = opts.max_rounds, .plugins = opts.plugins }, err);
    defer h.free();
    var app = h.app();
    defer app.deinit();

    const args = try buildArgs(gpa, argv, sub);
    defer ju.freeJsonValue(gpa, args);

    // 工作区只在进程内存在：先打开工程、再落约束，最后执行目标工具。
    const project_id = ju.objStr(args.object, "project");
    if (project_id.len > 0) {
        var open_args = ju.newObj(gpa);
        defer ju.freeJsonValue(gpa, open_args);
        try ju.putKey(gpa, &open_args.object, "id", try ju.strVal(gpa, project_id));
        const opened = try app.callTool("project_open", open_args);
        ju.freeJsonValue(gpa, opened);
    }

    if (cli.flagValue(argv, "--constraints")) |text| {
        const rules = try ju.parseValue(gpa, text);
        defer ju.freeJsonValue(gpa, rules);
        if (rules == .array and project_id.len > 0) {
            for (rules.array.items) |rule| {
                if (rule != .object) continue;
                var one = ju.newObj(gpa);
                defer ju.freeJsonValue(gpa, one);
                try ju.putKey(gpa, &one.object, "project", try ju.strVal(gpa, project_id));
                for ([_][]const u8{ "id", "kind", "direction", "severity" }) |key| {
                    try ju.putKey(gpa, &one.object, key, try ju.strVal(gpa, ju.objStr(rule.object, key)));
                }
                const limit = rule.object.get("limit") orelse continue;
                try ju.putKey(gpa, &one.object, "limit", .{ .float = numberFromValue(limit) });
                const applied = try app.callTool("project_set_constraint", one);
                ju.freeJsonValue(gpa, applied);
            }
        }
    }

    // 同一进程内先读取板框：DRC 与外壳配合需要板上的器件与焊盘。
    if (project_id.len > 0) {
        const path_flag = cli.flagValue(argv, "--path");
        const text_flag = cli.flagValue(argv, "--text");
        if (path_flag != null or text_flag != null) {
            var read_args = ju.newObj(gpa);
            defer ju.freeJsonValue(gpa, read_args);
            try ju.putKey(gpa, &read_args.object, "project", try ju.strVal(gpa, project_id));
            if (path_flag) |p| try ju.putKey(gpa, &read_args.object, "path", try ju.strVal(gpa, p));
            if (text_flag) |t| try ju.putKey(gpa, &read_args.object, "text", try ju.strVal(gpa, t));
            const read = try app.callTool("pcb_read", read_args);
            ju.freeJsonValue(gpa, read);
        }
    }

    const result = app.callTool(subToolName(sub), args) catch |e| {
        try err.print("设计工具失败: {s}\n", .{@errorName(e)});
        try err.flush();
        cli_common.exit(out, err, 1);
    };
    defer ju.freeJsonValue(gpa, result);

    try out.print("{s}\n", .{ju.objStr(result.object, "content")});
    try out.flush();
}

fn subToolName(sub: []const u8) []const u8 {
    if (std.mem.eql(u8, sub, "open")) return "project_open";
    if (std.mem.eql(u8, sub, "read")) return "pcb_read";
    if (std.mem.eql(u8, sub, "drc")) return "drc_check";
    if (std.mem.eql(u8, sub, "fit")) return "enclosure_fit";
    if (std.mem.eql(u8, sub, "rank")) return "design_rank";
    if (std.mem.eql(u8, sub, "skills")) return "skill_list";
    if (std.mem.eql(u8, sub, "constraint")) return "project_set_constraint";
    return sub;
}

/// 把命令行参数映射成工具入参 JSON。
pub fn buildArgs(gpa: Allocator, argv: []const []const u8, sub: []const u8) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);

    if (std.mem.eql(u8, sub, "open")) {
        if (argv.len >= 4) try ju.putKey(gpa, &obj.object, "id", try ju.strVal(gpa, argv[3]));
        if (argv.len >= 5) try ju.putKey(gpa, &obj.object, "name", try ju.strVal(gpa, argv[4]));
        return obj;
    }

    if (std.mem.eql(u8, sub, "skills")) return obj;

    if (argv.len >= 4) try ju.putKey(gpa, &obj.object, "project", try ju.strVal(gpa, argv[3]));

    if (std.mem.eql(u8, sub, "read")) {
        if (cli.flagValue(argv, "--path")) |p| try ju.putKey(gpa, &obj.object, "path", try ju.strVal(gpa, p));
        if (cli.flagValue(argv, "--text")) |t| try ju.putKey(gpa, &obj.object, "text", try ju.strVal(gpa, t));
        return obj;
    }

    if (std.mem.eql(u8, sub, "constraint")) {
        if (argv.len >= 5) try ju.putKey(gpa, &obj.object, "id", try ju.strVal(gpa, argv[4]));
        if (argv.len >= 6) try ju.putKey(gpa, &obj.object, "kind", try ju.strVal(gpa, argv[5]));
        if (argv.len >= 7) try putNumber(gpa, &obj.object, "limit", argv[6]);
        if (argv.len >= 8) try ju.putKey(gpa, &obj.object, "direction", try ju.strVal(gpa, argv[7]));
        if (argv.len >= 9) try ju.putKey(gpa, &obj.object, "severity", try ju.strVal(gpa, argv[8]));
        return obj;
    }

    if (std.mem.eql(u8, sub, "fit")) {
        if (argv.len >= 5) try putNumber(gpa, &obj.object, "width", argv[4]);
        if (argv.len >= 6) try putNumber(gpa, &obj.object, "height", argv[5]);
        if (argv.len >= 7) try putNumber(gpa, &obj.object, "wall", argv[6]);
        if (cli.flagValue(argv, "--shell-height")) |v| try putNumber(gpa, &obj.object, "shell_height", v);
        if (cli.hasFlag(argv, "--apply")) try ju.putKey(gpa, &obj.object, "apply", .{ .bool = true });
        return obj;
    }

    if (std.mem.eql(u8, sub, "rank")) {
        const file = cli.flagValue(argv, "--file");
        const inline_json = cli.flagValue(argv, "--candidates");
        var text: []const u8 = "[]";
        var owned = false;
        if (file) |f| {
            text = try ioc.cwd().readFileAlloc(gpa, f, 256 * 1024);
            owned = true;
        } else if (inline_json) |v| text = v;

        const parsed = try ju.parseValue(gpa, text);
        defer if (owned) gpa.free(text);

        var candidates: std.json.Value = .null;
        if (parsed == .array) {
            candidates = try ju.copyJsonValue(gpa, parsed);
        } else if (parsed == .object) {
            candidates = ju.objGet(parsed.object, "candidates") orelse .null;
            // 基准文件形态：从第一个用例取候选（与 benchmarks/pcb/cases.json 一致）。
            if (candidates == .null) {
                if (ju.objGet(parsed.object, "cases")) |cases| {
                    if (cases == .array and cases.array.items.len > 0 and cases.array.items[0] == .object) {
                        candidates = cases.array.items[0].object.get("candidates") orelse .null;
                    }
                }
            }
            candidates = try ju.copyJsonValue(gpa, candidates);
        }
        ju.freeJsonValue(gpa, parsed);
        try ju.putKey(gpa, &obj.object, "candidates", candidates);
        return obj;
    }

    return obj;
}

fn putNumber(gpa: Allocator, map: *std.json.ObjectMap, key: []const u8, text: []const u8) !void {
    const value = try std.fmt.parseFloat(f64, text);
    try ju.putKey(gpa, map, key, .{ .float = value });
}

fn numberFromValue(value: std.json.Value) f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => 0.0,
    };
}

test "design cli maps arguments to tool inputs" {
    const gpa = std.testing.allocator;

    const open_argv = [_][]const u8{ "cuteclaw", "design", "open", "demo", "Demo Board" };
    const args = try buildArgs(gpa, &open_argv, "open");
    defer ju.freeJsonValue(gpa, args);
    try std.testing.expectEqualStrings("demo", ju.objStr(args.object, "id"));
    try std.testing.expectEqualStrings("Demo Board", ju.objStr(args.object, "name"));

    const fit_argv = [_][]const u8{ "cuteclaw", "design", "fit", "demo", "60", "40", "2", "--shell-height", "15", "--apply" };
    const fit = try buildArgs(gpa, &fit_argv, "fit");
    defer ju.freeJsonValue(gpa, fit);
    // 数字参数以 .float 落进工具入参：这里断言数值而不是字符串。
    try std.testing.expectEqual(@as(f64, 60), fit.object.get("width").?.float);
    try std.testing.expectEqual(@as(f64, 15), fit.object.get("shell_height").?.float);
    try std.testing.expect(fit.object.get("apply").?.bool);

    const rank_argv = [_][]const u8{ "cuteclaw", "design", "rank", "demo", "--candidates", "[{\"id\":\"A\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"\"}]},{\"id\":\"C\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":3,\"ref\":\"\"}]},{\"id\":\"B\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"\"}]}]" };
    const ranked = try buildArgs(gpa, &rank_argv, "rank");
    defer ju.freeJsonValue(gpa, ranked);
    try std.testing.expectEqual(@as(usize, 3), ranked.object.get("candidates").?.array.items.len);

    try std.testing.expectEqualStrings("design_rank", subToolName("rank"));
    try std.testing.expectEqualStrings("drc_check", subToolName("drc"));
}

test "design rank eliminates hard violations through the tool" {
    const gpa = std.testing.allocator;
    const h = try host.Host.init(gpa, .{ .model = "m" }, .{});
    defer h.free();
    var app = h.app();
    defer app.deinit();

    const args = try ju.parseValue(gpa, "{\"project\":\"demo\",\"candidates\":[{\"id\":\"A\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"\"},{\"kind\":\"rat_length\",\"value\":820,\"ref\":\"\"}]},{\"id\":\"B\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"\"},{\"kind\":\"rat_length\",\"value\":670,\"ref\":\"\"}]},{\"id\":\"C\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":3,\"ref\":\"\"},{\"kind\":\"rat_length\",\"value\":590,\"ref\":\"\"}]}]}");
    defer ju.freeJsonValue(gpa, args);

    const open_args = try ju.parseValue(gpa, "{\"id\":\"demo\",\"name\":\"bench\"}");
    defer ju.freeJsonValue(gpa, open_args);
    const opened = try app.callTool("project_open", open_args);
    ju.freeJsonValue(gpa, opened);

    const hard = try ju.parseValue(gpa, "{\"project\":\"demo\",\"id\":\"r1\",\"kind\":\"drc_errors\",\"limit\":0,\"direction\":\"max\",\"severity\":\"hard\"}");
    defer ju.freeJsonValue(gpa, hard);
    const set_hard = try app.callTool("project_set_constraint", hard);
    ju.freeJsonValue(gpa, set_hard);

    // 与 canonical benchmark 一致：还需要一条软约束提供可比较的优化代价。
    const soft = try ju.parseValue(gpa, "{\"project\":\"demo\",\"id\":\"r2\",\"kind\":\"rat_length\",\"limit\":900,\"direction\":\"max\",\"severity\":\"soft\"}");
    defer ju.freeJsonValue(gpa, soft);
    const set_soft = try app.callTool("project_set_constraint", soft);
    ju.freeJsonValue(gpa, set_soft);

    const ranked = try app.callTool("design_rank", args);
    defer ju.freeJsonValue(gpa, ranked);
    const content = try ju.parseValue(gpa, ju.objStr(ranked.object, "content"));
    defer ju.freeJsonValue(gpa, content);

    try std.testing.expectEqual(@as(usize, 3), content.array.items.len);
    try std.testing.expectEqualStrings("B", ju.objStr(content.array.items[0].object, "id"));
    try std.testing.expect(content.array.items[2].object.get("eliminated").?.bool);
}
