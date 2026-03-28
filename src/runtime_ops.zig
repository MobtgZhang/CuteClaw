//! CLI 与 HTTP 共用的状态 / 配置展示文本（避免 main 与 serve 重复）。

const std = @import("std");
const cuteclaw = @import("cuteclaw");

/// 与 `cuteclaw status` 文本输出一致。
pub fn writeStatusText(w: anytype, rt: *cuteclaw.ClawRuntime, store_path: []const u8, config_path: []const u8) !void {
    try w.print("store: {s}\n", .{store_path});
    if (std.fs.cwd().access(config_path, .{})) |_| {
        try w.print("config: {s} (存在)\n", .{config_path});
    } else |_| {
        try w.print("config: {s} (不存在)\n", .{config_path});
    }
    try w.print("schema: v{} (库版本 {s})\n", .{ cuteclaw.persist.schema_version_v1, cuteclaw.version });
    try w.print("episodic: {}  skills: {}  facts: {}\n", .{
        rt.episodic.items.len, rt.skills.items.len, rt.facts.items.len,
    });
    try w.print("tasks_recorded: {}  tasks_succeeded: {}\n", .{
        rt.metrics.tasks_recorded, rt.metrics.tasks_succeeded,
    });
    try w.print("audit_tail: {}  rollups: {}\n", .{
        rt.metrics.audit.items.len,
        rt.metrics.rollupCount(),
    });
    if (!rt.working.isEmpty()) {
        var wbuf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&wbuf);
        try rt.working.formatBlock(fbs.writer());
        try w.print("{s}", .{fbs.getWritten()});
    }
}

/// 分配缓冲区并写入 status 文本；调用方 `defer gpa.free(slice)`。
pub fn allocStatusText(gpa: std.mem.Allocator, rt: *cuteclaw.ClawRuntime, store_path: []const u8, config_path: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    const wr = list.writer(gpa);
    try writeStatusText(wr, rt, store_path, config_path);
    return try list.toOwnedSlice(gpa);
}

/// 与 `cuteclaw config show` 文本输出一致（文件不存在时输出提示）。
pub fn writeConfigShowText(gpa: std.mem.Allocator, w: anytype, config_path: []const u8) !void {
    var cfg = cuteclaw.config.loadApiConfigFromPath(gpa, config_path) catch |e| switch (e) {
        error.FileNotFound => {
            try w.print("config: {s}\n(文件不存在，可执行 config init 生成模板)\n", .{config_path});
            return;
        },
        else => return e,
    };
    defer cfg.deinit(gpa);

    try w.print("config: {s}\n", .{config_path});
    try w.print("schema_version: {}\n", .{cfg.schema_version});
    try w.print("provider: {s}\n", .{cfg.provider});
    try w.print("api_base: {s}\n", .{cfg.api_base});
    try w.print("api_key_file: {s}\n", .{cfg.api_key_file});
    try w.print("api_key_env: {s}\n", .{cfg.api_key_env});
    try w.print("model: {s}\n", .{cfg.model});
    try w.print("connect_timeout_sec: {}\nread_timeout_sec: {}\n", .{ cfg.connect_timeout_sec, cfg.read_timeout_sec });

    var key_file_ok = false;
    if (cfg.api_key_file.len > 0) {
        if (std.fs.cwd().access(cfg.api_key_file, .{})) |_| {
            key_file_ok = true;
        } else |_| {}
    }
    try w.print("api_key_file_readable: {}\n", .{key_file_ok});

    if (std.process.getEnvVarOwned(gpa, cfg.api_key_env)) |v| {
        defer gpa.free(v);
        try w.print("api_key_env_present: true (长度 {})\n", .{v.len});
    } else |_| {
        try w.print("api_key_env_present: false\n", .{});
    }

    if (try cuteclaw.config.loadApiKeyMaterial(gpa, &cfg)) |secret| {
        defer gpa.free(secret);
        try w.print("resolved_key_material: 是 (长度 {}，内容已隐藏)\n", .{secret.len});
    } else {
        try w.print("resolved_key_material: 否\n", .{});
    }

    try w.print("extra_headers: {} 条（勿在版本库中提交敏感头）\n", .{cfg.extra_headers.len});
    for (cfg.extra_headers) |h| {
        try w.print("  - {s}: {s}\n", .{ h.name, h.value });
    }
}

pub fn allocConfigShowText(gpa: std.mem.Allocator, config_path: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    try writeConfigShowText(gpa, list.writer(gpa), config_path);
    return try list.toOwnedSlice(gpa);
}

/// 与 `cuteclaw evolve` 成功路径下的 stdout 文案一致（供 HTTP /api/evolve）。
pub fn allocEvolveStdout(gpa: std.mem.Allocator, d: cuteclaw.evolution.MergeDecision) ![]u8 {
    return switch (d) {
        .accepted => |s| try std.fmt.allocPrint(gpa, "已接受: {s}@{s}\n", .{ s.name, s.version }),
        .rejected => |r| try std.fmt.allocPrint(gpa, "拒绝: {s}\n", .{r}),
        .deferred => try gpa.dupe(u8, "推迟（dry_run 或需人工）\n"),
    };
}
