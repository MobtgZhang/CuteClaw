//! CLI 公共辅助：参数解析、配置装载与 Host 装配（chat / plugin / design 共用）。
//! 配置文件缺失时退回默认值，使离线与无密钥场景仍可运行。

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const llm = @import("core/llm.zig");
const host = @import("host.zig");
const ioc = @import("ioctx");

/// 退出前必须 flush：用法与错误文本写在缓冲 writer 里，直接 exit 会丢失。
pub fn exit(out: anytype, err: anytype, code: u8) noreturn {
    out.flush() catch {};
    err.flush() catch {};
    std.process.exit(code);
}

pub fn flagValue(argv: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], name) and i + 1 < argv.len) return argv[i + 1];
    }
    return null;
}

pub fn hasFlag(argv: []const []const u8, name: []const u8) bool {
    for (argv[2..]) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// 同名旗标可重复（例如多次 `--plugin`）。
pub fn flagValues(gpa: Allocator, argv: []const []const u8, name: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(
        gpa,
    );
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], name) and i + 1 < argv.len) {
            try list.append(gpa, try gpa.dupe(u8, argv[i + 1]));
            i += 1;
        }
    }
    return list.toOwnedSlice(
        gpa,
    );
}

pub fn resolveConfigPath(gpa: Allocator, argv: []const []const u8) ![]const u8 {
    if (flagValue(argv, "--config")) |p| return try gpa.dupe(u8, p);
    if (ioc.envOwned(gpa, "CUTECLAW_CONFIG")) |p| return p else |_| {}
    return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ config.default_data_dir, config.default_config_file });
}

pub fn freeLlmConfig(gpa: Allocator, c: *const llm.Config) void {
    gpa.free(c.api_key);
    gpa.free(c.api_base);
    gpa.free(c.model);
    for (c.extra_headers) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(c.extra_headers);
}

/// 返回完全由 `gpa` 持有的配置（调用方用 `freeLlmConfig` 释放）。
pub fn loadLlmConfig(gpa: Allocator, path: []const u8) !llm.Config {
    var cfg = config.loadApiConfigFromPath(gpa, path) catch |e| switch (e) {
        error.FileNotFound => return defaultLlmConfig(gpa),
        else => return e,
    };
    defer cfg.deinit(gpa);

    const base = try host.Host.llmConfig(gpa, &cfg);
    var owned: llm.Config = .{
        .provider = base.provider,
        .api_base = try gpa.dupe(u8, base.api_base),
        .api_key = base.api_key,
        .model = try gpa.dupe(u8, base.model),
        .connect_timeout_ms = base.connect_timeout_ms,
        .read_timeout_ms = base.read_timeout_ms,
        .temperature = base.temperature,
        .top_p = base.top_p,
        .max_tokens = base.max_tokens,
    };
    errdefer freeLlmConfig(gpa, &owned);

    const headers = try gpa.alloc(std.http.Header, base.extra_headers.len);
    errdefer gpa.free(headers);
    for (base.extra_headers, 0..) |h, i| {
        headers[i] = .{ .name = try gpa.dupe(u8, h.name), .value = try gpa.dupe(u8, h.value) };
    }
    owned.extra_headers = headers;
    return owned;
}

pub fn defaultLlmConfig(gpa: Allocator) !llm.Config {
    return .{
        .api_base = try gpa.dupe(u8, "https://api.openai.com/v1"),
        .api_key = try gpa.dupe(u8, ""),
        .model = try gpa.dupe(u8, ""),
    };
}

pub const HostOptions = struct {
    workspace_root: []const u8 = ".",
    event_log_path: []const u8 = "",
    max_rounds: usize = 12,
    plugins: []const []const u8 = &.{},
};

/// 装配 Host 并加载 `--plugin` 清单；单个插件失败只告警，不阻断会话。
pub fn buildHost(gpa: Allocator, argv: []const []const u8, opts: HostOptions, err: *std.Io.Writer) !*host.Host {
    const cfg_path = try resolveConfigPath(gpa, argv);
    defer gpa.free(cfg_path);

    var llm_config = try loadLlmConfig(gpa, cfg_path);
    defer freeLlmConfig(gpa, &llm_config);

    const h = try host.Host.init(gpa, llm_config, .{
        .workspace_root = opts.workspace_root,
        .event_log_path = opts.event_log_path,
        .max_rounds = opts.max_rounds,
    });
    errdefer h.free();

    for (opts.plugins) |p| {
        h.loadPlugin(p) catch |e| {
            err.print("插件 {s} 加载失败: {s}\n", .{ p, @errorName(e) }) catch {};
        };
    }
    return h;
}

test "cli flag helpers" {
    const gpa = std.testing.allocator;
    const argv = [_][]const u8{ "cuteclaw", "chat", "--config", "a.json", "--plugin", "x", "--plugin", "y", "--json" };
    try std.testing.expectEqualStrings("a.json", flagValue(&argv, "--config").?);
    try std.testing.expect(hasFlag(&argv, "--json"));
    try std.testing.expect(!hasFlag(&argv, "--nope"));

    const plugins = try flagValues(gpa, &argv, "--plugin");
    defer {
        for (plugins) |p| gpa.free(p);
        gpa.free(plugins);
    }
    try std.testing.expectEqual(@as(usize, 2), plugins.len);
    try std.testing.expectEqualStrings("x", plugins[0]);
    try std.testing.expectEqualStrings("y", plugins[1]);

    const cfg_path = try resolveConfigPath(gpa, &argv);
    defer gpa.free(cfg_path);
    try std.testing.expectEqualStrings("a.json", cfg_path);
}

test "cli llm config falls back to defaults" {
    const gpa = std.testing.allocator;
    var c = try loadLlmConfig(gpa, "does-not-exist-config.json");
    defer freeLlmConfig(gpa, &c);
    try std.testing.expectEqual(llm.Provider.openai_compat, c.provider);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", c.api_base);
    try std.testing.expectEqual(@as(usize, 0), c.api_key.len);
}
