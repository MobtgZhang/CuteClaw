//! Agent cache 下的 memory 目录 CLI（与 web 项目布局一致：cache/projects/<project>/memory）
const std = @import("std");

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn flagValue(argv: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (eql(argv[i], name) and i + 1 < argv.len)
            return argv[i + 1];
    }
    return null;
}

fn memoryRootPath(gpa: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const cache = flagValue(argv, "--cache") orelse "cache";
    const project = flagValue(argv, "--project") orelse "default";
    return try std.fmt.allocPrint(gpa, "{s}/projects/{s}/memory", .{ cache, project });
}

pub fn cmdMemory(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    if (argv.len < 4) {
        try err.writeAll(
            \\用法: memory [--cache DIR] [--project ID] <子命令>
            \\
            \\  list              列出 memory 下相对路径（递归，最大深度 6）
            \\  get <rel>         打印文件内容（utf-8）
            \\  put <rel>         从 stdin 写入文件（创建父目录）
            \\  rm <rel>          删除文件
            \\
            \\默认 --cache cache --project default（相对当前工作目录）
            \\
        );
        std.process.exit(2);
    }
    const sub = argv[3];
    const root = try memoryRootPath(gpa, argv);
    defer gpa.free(root);

    if (eql(sub, "list")) {
        try cmdMemoryList(gpa, out, err, root);
        return;
    }
    if (eql(sub, "get")) {
        if (argv.len < 5) {
            try err.writeAll("用法: memory … get <rel>\n");
            std.process.exit(2);
        }
        try cmdMemoryGet(gpa, out, err, root, argv[4]);
        return;
    }
    if (eql(sub, "put")) {
        if (argv.len < 5) {
            try err.writeAll("用法: memory … put <rel>  （从 stdin 读）\n");
            std.process.exit(2);
        }
        try cmdMemoryPut(gpa, err, root, argv[4]);
        return;
    }
    if (eql(sub, "rm")) {
        if (argv.len < 5) {
            try err.writeAll("用法: memory … rm <rel>\n");
            std.process.exit(2);
        }
        try cmdMemoryRm(gpa, err, root, argv[4]);
        return;
    }
    try err.print("未知 memory 子命令: {s}\n", .{sub});
    std.process.exit(2);
}

fn isSafeRel(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    return true;
}

fn cmdMemoryList(gpa: std.mem.Allocator, out: anytype, err: anytype, root: []const u8) !void {
    std.fs.cwd().access(root, .{}) catch {
        try err.print("目录不存在: {s}\n", .{root});
        std.process.exit(1);
    };
    try walkMemoryRel(gpa, out, root, "", 0, 6);
}

fn walkMemoryRel(
    gpa: std.mem.Allocator,
    out: anytype,
    root_base: []const u8,
    sub: []const u8,
    depth: u32,
    max_depth: u32,
) !void {
    if (depth > max_depth) return;
    const cur = if (sub.len == 0)
        root_base
    else
        try std.fs.path.join(gpa, &.{ root_base, sub });
    defer if (sub.len != 0) gpa.free(cur);

    var d = std.fs.cwd().openDir(cur, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |ent| {
        if (ent.name[0] == '.') continue;
        const rel_disp = if (sub.len == 0)
            try gpa.dupe(u8, ent.name)
        else
            try std.fs.path.join(gpa, &.{ sub, ent.name });
        defer gpa.free(rel_disp);
        switch (ent.kind) {
            .directory => try walkMemoryRel(gpa, out, root_base, rel_disp, depth + 1, max_depth),
            .file => try out.print("{s}\n", .{rel_disp}),
            else => {},
        }
    }
}

fn joinRootRel(gpa: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (!isSafeRel(rel)) return error.BadRel;
    return std.fs.path.join(gpa, &.{ root, rel });
}

fn cmdMemoryGet(gpa: std.mem.Allocator, out: anytype, err: anytype, root: []const u8, rel: []const u8) !void {
    const full = joinRootRel(gpa, root, rel) catch {
        try err.writeAll("非法路径 rel\n");
        std.process.exit(2);
    };
    defer gpa.free(full);
    const data = std.fs.cwd().readFileAlloc(gpa, full, 8 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => {
            try err.print("未找到: {s}\n", .{rel});
            std.process.exit(1);
        },
        else => return e,
    };
    defer gpa.free(data);
    try out.writeAll(data);
}

fn cmdMemoryPut(gpa: std.mem.Allocator, err: anytype, root: []const u8, rel: []const u8) !void {
    const full = joinRootRel(gpa, root, rel) catch {
        try err.writeAll("非法路径 rel\n");
        std.process.exit(2);
    };
    defer gpa.free(full);
    const parent = std.fs.path.dirname(full) orelse {
        try err.writeAll("无效路径\n");
        std.process.exit(2);
    };
    try std.fs.cwd().makePath(parent);
    const file = try std.fs.cwd().createFile(full, .{});
    defer file.close();
    const stdin = std.fs.File.stdin();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) break;
        try file.writeAll(buf[0..n]);
    }
}

fn cmdMemoryRm(gpa: std.mem.Allocator, err: anytype, root: []const u8, rel: []const u8) !void {
    const full = joinRootRel(gpa, root, rel) catch {
        try err.writeAll("非法路径 rel\n");
        std.process.exit(2);
    };
    defer gpa.free(full);
    std.fs.cwd().deleteFile(full) catch |e| switch (e) {
        error.FileNotFound => {
            try err.print("未找到: {s}\n", .{rel});
            std.process.exit(1);
        },
        else => return e,
    };
}
