//! FreeCAD 适配器：控制平面仍在 Zig，FreeCAD 作为受策略约束的外部工具进程运行。
//! 命令构建与结果解析均为纯函数，便于测试与审计。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const ioc = @import("ioctx");
const geometry = @import("../design/geometry.zig");
const pcb = @import("../design/pcb.zig");
const project = @import("../design/project.zig");
const sandbox = @import("../sandbox/policy.zig");

const Allocator = std.mem.Allocator;

pub const AdapterError = error{
    BadCommand,
    BadResult,
    CapabilityDenied,
    PathOutsideWorkspace,
    ProcessFailed,
};

pub const Options = struct {
    binary: []const u8,
    script: []const u8,
    workdir: []const u8,
    timeout_ms: u64,

    pub fn free(self: *const Options, gpa: Allocator) void {
        gpa.free(self.binary);
        gpa.free(self.script);
        gpa.free(self.workdir);
    }
};

pub fn buildCommand(gpa: Allocator, opts: *const Options) ![]const []const u8 {
    if (opts.binary.len == 0) return error.BadCommand;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(
        gpa,
    );
    try list.append(gpa, try gpa.dupe(u8, opts.binary));
    try list.append(gpa, try gpa.dupe(u8, "--console"));
    try list.append(gpa, try gpa.dupe(u8, opts.script));
    return list.toOwnedSlice(
        gpa,
    );
}

/// 参数化外壳脚本：按工程需求生成实体并输出 JSON（供 parseResult 消费）。
pub fn enclosureScript(gpa: Allocator, p: *const project.DesignProject) ![]const u8 {
    const enc = p.enclosure orelse return error.BadCommand;
    const cavity = enc.cavity();
    return std.fmt.allocPrint(gpa,
        \\import json, FreeCAD
        \\doc = FreeCAD.newDocument("cuteclaw")
        \\part = doc.addObject("Part::Box", "shell")
        \\part.Length = {d:.3f}
        \\part.Width = {d:.3f}
        \\part.Height = {d:.3f}
        \\board = doc.addObject("Part::Box", "pcb")
        \\board.Length = {d:.3f}
        \\board.Width = {d:.3f}
        \\board.Height = 1.6
        \\doc.recompute()
        \\print(json.dumps({{"entity_count": len(doc.Objects), "volume_mm3": part.Volume, "fit_clearance": {d:.3f}, "message": "ok"}}))
    , .{
        cavity.width(),
        cavity.height(),
        enc.height,
        p.board.bounds.width(),
        p.board.bounds.height(),
        enc.fitClearance(&p.board),
    });
}

pub const Result = struct {
    gpa: Allocator,
    ok: bool,
    entity_count: usize,
    volume_mm3: f64,
    fit_clearance: f64,
    message: []const u8,

    pub fn free(self: *const Result) void {
        self.gpa.free(self.message);
    }

    pub fn toJson(self: *const Result) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "ok", .{ .bool = self.ok });
        try ju.putKey(self.gpa, &obj.object, "entity_count", .{ .integer = @intCast(self.entity_count) });
        try ju.putKey(self.gpa, &obj.object, "volume_mm3", .{ .float = self.volume_mm3 });
        try ju.putKey(self.gpa, &obj.object, "fit_clearance", .{ .float = self.fit_clearance });
        try ju.putKey(self.gpa, &obj.object, "message", try ju.strVal(self.gpa, self.message));
        return obj;
    }
};

pub fn parseResult(gpa: Allocator, stdout_text: []const u8) !Result {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, stdout_text, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadResult,
    };
    const ok_value = ju.objGet(root, "ok");
    return .{
        .gpa = gpa,
        .ok = if (ok_value) |v| switch (v) {
            .bool => |b| b,
            else => true,
        } else true,
        .entity_count = ju.objNum(root, "entity_count"),
        .volume_mm3 = numberField(root, "volume_mm3"),
        .fit_clearance = numberField(root, "fit_clearance"),
        .message = try gpa.dupe(u8, ju.objStr(root, "message")),
    };
}

fn numberField(obj: std.json.ObjectMap, key: []const u8) f64 {
    const v = ju.objGet(obj, key) orelse return 0.0;
    switch (v) {
        .integer => |i| return @floatFromInt(i),
        .float => |f| return f,
        else => return 0.0,
    }
}

/// 在策略允许的前提下执行外部进程；返回 stdout 文本（调用方释放）。
pub fn run(gpa: Allocator, opts: *const Options, policy: *const sandbox.Policy) ![]const u8 {
    try policy.checkCapability(.run_tool);
    try policy.checkPath(opts.workdir);

    const argv = try buildCommand(gpa, opts);
    defer {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }

    var child = try std.process.spawn(ioc.io(), .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer {
        if (child.stdout) |f| ioc.File.wrap(f).close();
        if (child.stderr) |f| ioc.File.wrap(f).close();
    }

    // 先读空 stdout 再 wait，避免管道写满造成父子进程互相等待。
    const out = try ioc.File.wrap(child.stdout.?).readToEndAlloc(gpa, 1024 * 1024);
    const term = try child.wait(ioc.io());
    switch (term) {
        .exited => |code| if (code != 0) return error.ProcessFailed,
        else => return error.ProcessFailed,
    }
    return out;
}

/// 纯几何配合检查：不依赖 FreeCAD 是否安装。
pub fn fitCheck(enc: *const project.Enclosure, board: *const pcb.Board, min_clearance: f64) bool {
    const clearance = enc.fitClearance(board);
    if (clearance < min_clearance) return false;
    const cavity = enc.cavity();
    for (board.components.items) |c| {
        if (!cavity.containsRect(c.courtyard())) return false;
    }
    return true;
}

pub fn enclosureFromBoard(gpa: Allocator, name: []const u8, board: *const pcb.Board, wall: f64, height: f64, margin: f64) !project.Enclosure {
    const outer = board.bounds.expand(margin + wall);
    return .{
        .name = try gpa.dupe(u8, name),
        .outer = outer,
        .wall = wall,
        .height = height,
    };
}

test "freecad command and result" {
    const gpa = std.testing.allocator;
    const opts = Options{
        .binary = "freecad",
        .script = "/tmp/s.py",
        .workdir = "/tmp",
        .timeout_ms = 5000,
    };

    const argv = try buildCommand(gpa, &opts);
    defer {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("--console", argv[1]);

    var res = try parseResult(gpa, "{\"ok\":true,\"entity_count\":4,\"volume_mm3\":1200.5,\"fit_clearance\":2.0,\"message\":\"ok\"}");
    defer res.free();
    try std.testing.expect(res.ok);
    try std.testing.expectEqual(@as(usize, 4), res.entity_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1200.5), res.volume_mm3, 0.0001);

    const json = try res.toJson();
    defer ju.freeJsonValue(gpa, json);
    try std.testing.expect(std.mem.indexOf(u8, ju.objStr(json.object, "message"), "o") != null);
}

test "freecad run is policy gated" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "/tmp");
    const opts = Options{ .binary = "freecad", .script = "s.py", .workdir = "/tmp", .timeout_ms = 1000 };
    try std.testing.expectError(error.CapabilityDenied, run(gpa, &opts, &policy));
    try policy.grant(.read_file);
    try policy.grant(.run_tool);
    // 工作区外的路径必须在启动进程前就被拒绝，否则测试会真的去执行 freecad。
    const outside = Options{ .binary = "freecad", .script = "s.py", .workdir = "/etc", .timeout_ms = 1000 };
    try std.testing.expectError(error.PathOutsideWorkspace, run(gpa, &outside, &policy));
}

test "enclosure fit check" {
    const gpa = std.testing.allocator;
    var board = try pcb.Board.init(gpa, "fit");
    defer board.deinit();
    board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 40, .y = 30 } };
    try board.addComponent(.{ .ref = "U1", .footprint = "QFP", .center = .{ .x = 20, .y = 15 }, .rotation_deg = 0, .width = 7, .height = 7, .courtyard_margin = 0.25 });

    const enc = try enclosureFromBoard(gpa, "shell", &board, 2.0, 12.0, 1.0);
    defer gpa.free(enc.name);
    try std.testing.expect(fitCheck(&enc, &board, 0.5));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), enc.fitClearance(&board), 0.0001);

    const tight = project.Enclosure{ .name = "tight", .outer = board.bounds.expand(2.0), .wall = 2.0, .height = 10 };
    try std.testing.expect(!fitCheck(&tight, &board, 0.5));
}
