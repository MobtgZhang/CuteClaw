//! 数据目录、默认路径与 **API 配置**（`config.json`）。
//! 密钥仅通过「密钥文件路径」或环境变量名引用，不把明文密钥写入 JSON。

const std = @import("std");

const Allocator = std.mem.Allocator;

/// 默认数据目录（相对当前工作目录）。
pub const default_data_dir = ".cuteclaw";

/// 默认快照文件名。
pub const default_store_file = "store.json";

/// 默认 API 配置文件名（与 `store.json` 同目录）。
pub const default_config_file = "config.json";

/// `config.json` 根对象的 `schema_version` 当前值。
pub const api_config_schema_version: u32 = 1;

pub const max_config_file_bytes: usize = 256 * 1024;

pub fn defaultStorePath(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ default_data_dir, default_store_file }) catch null;
}

pub fn defaultConfigPath(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ default_data_dir, default_config_file }) catch null;
}

// --- JSON 形状（与磁盘 `config.json` 一致）---

pub const ApiHeaderJson = struct {
    name: []const u8,
    value: []const u8,
};

/// 与 `examples/config.json` 字段一致；缺省字段由解析器填默认值。
pub const ApiConfigJson = struct {
    schema_version: u32 = api_config_schema_version,
    /// 约定：`openai_compat` | `anthropic_compat` | `custom`（宿主自行解释）
    provider: []const u8 = "openai_compat",
    /// OpenAI 兼容一般为 `https://host/v1`；可按部署改为代理或自建网关
    api_base: []const u8 = "https://api.openai.com/v1",
    /// 存放 API Key 的文件路径（推荐）；空则仅看环境变量
    api_key_file: []const u8 = "",
    /// 当 `api_key_file` 为空或读失败时，尝试此环境变量
    api_key_env: []const u8 = "OPENAI_API_KEY",
    model: []const u8 = "",
    connect_timeout_sec: u32 = 30,
    read_timeout_sec: u32 = 120,
    /// 附加 HTTP 头（敏感头请谨慎；不要在此写密钥明文）
    extra_headers: []const ApiHeaderJson = &.{},
};

/// 解析后的可长期持有副本（各字符串由 `gpa` 分配）。
pub const ApiConfigOwned = struct {
    schema_version: u32,
    provider: []u8,
    api_base: []u8,
    api_key_file: []u8,
    api_key_env: []u8,
    model: []u8,
    connect_timeout_sec: u32,
    read_timeout_sec: u32,
    extra_headers: []ApiHeaderOwned,

    pub const ApiHeaderOwned = struct {
        name: []u8,
        value: []u8,
    };

    pub fn deinit(self: *ApiConfigOwned, gpa: Allocator) void {
        gpa.free(self.provider);
        gpa.free(self.api_base);
        gpa.free(self.api_key_file);
        gpa.free(self.api_key_env);
        gpa.free(self.model);
        for (self.extra_headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.extra_headers);
        self.* = undefined;
    }
};

fn dupeJsonToOwned(gpa: Allocator, j: ApiConfigJson) !ApiConfigOwned {
    const provider = try gpa.dupe(u8, j.provider);
    errdefer gpa.free(provider);
    const api_base = try gpa.dupe(u8, j.api_base);
    errdefer gpa.free(api_base);
    const api_key_file = try gpa.dupe(u8, j.api_key_file);
    errdefer gpa.free(api_key_file);
    const api_key_env = try gpa.dupe(u8, j.api_key_env);
    errdefer gpa.free(api_key_env);
    const model = try gpa.dupe(u8, j.model);
    errdefer gpa.free(model);

    var header_list = std.ArrayList(ApiConfigOwned.ApiHeaderOwned).empty;
    errdefer {
        for (header_list.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        header_list.deinit(gpa);
    }
    for (j.extra_headers) |eh| {
        try header_list.append(gpa, .{
            .name = try gpa.dupe(u8, eh.name),
            .value = try gpa.dupe(u8, eh.value),
        });
    }
    const headers_slice = try header_list.toOwnedSlice(gpa);

    return .{
        .schema_version = j.schema_version,
        .provider = provider,
        .api_base = api_base,
        .api_key_file = api_key_file,
        .api_key_env = api_key_env,
        .model = model,
        .connect_timeout_sec = j.connect_timeout_sec,
        .read_timeout_sec = j.read_timeout_sec,
        .extra_headers = headers_slice,
    };
}

/// 从路径读取并复制为 `ApiConfigOwned`（文件不存在则返回 `error.FileNotFound`）。
/// 另可能返回 `error.UnsupportedApiConfigSchema` 与 JSON 解析错误。
pub fn loadApiConfigFromPath(gpa: Allocator, path: []const u8) !ApiConfigOwned {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(gpa, max_config_file_bytes);
    defer gpa.free(data);

    var parsed = try std.json.parseFromSlice(ApiConfigJson, gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.schema_version != api_config_schema_version)
        return error.UnsupportedApiConfigSchema;

    return try dupeJsonToOwned(gpa, parsed.value);
}

/// 默认模板（格式化写入磁盘）；与 `ApiConfigJson` 默认值语义一致。
pub fn defaultApiConfigJsonPretty(gpa: Allocator) Allocator.Error![]u8 {
    const tmpl: ApiConfigJson = .{};
    return std.json.Stringify.valueAlloc(gpa, tmpl, .{ .whitespace = .indent_2 });
}

/// 原子写入 `path`（同目录下 `basename.tmp` → rename）。
pub fn writeApiConfigAtomic(gpa: Allocator, path: []const u8, json_bytes: []const u8) !void {
    const dirname = std.fs.path.dirname(path) orelse ".";
    const file_name = std.fs.path.basename(path);
    try std.fs.cwd().makePath(dirname);
    var dir = try std.fs.cwd().openDir(dirname, .{});
    defer dir.close();
    const tmp_name = try std.fmt.allocPrint(gpa, "{s}.tmp", .{file_name});
    defer gpa.free(tmp_name);
    try dir.writeFile(.{ .sub_path = tmp_name, .data = json_bytes });
    try dir.rename(tmp_name, file_name);
}

/// 写入内置默认模板（`--force` 时覆盖已存在文件）。
pub fn writeDefaultApiConfigToPath(gpa: Allocator, path: []const u8) !void {
    const bytes = try defaultApiConfigJsonPretty(gpa);
    defer gpa.free(bytes);
    try writeApiConfigAtomic(gpa, path, bytes);
}

/// 尝试解析 API Key：优先读 `api_key_file`（去首尾空白），否则读 `api_key_env` 环境变量。
/// 返回值由 `gpa` 分配，调用方 `defer gpa.free(slice)`；无密钥时返回 `null`。
pub fn loadApiKeyMaterial(gpa: Allocator, cfg: *const ApiConfigOwned) !?[]u8 {
    if (cfg.api_key_file.len > 0) {
        const raw = std.fs.cwd().readFileAlloc(gpa, cfg.api_key_file, 64 * 1024) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer gpa.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try gpa.dupe(u8, trimmed);
    }
    const from_env = std.process.getEnvVarOwned(gpa, cfg.api_key_env) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => |err| return err,
    };
    return from_env;
}

test "parse api config defaults" {
    const gpa = std.testing.allocator;
    const minimal =
        \\{"schema_version":1}
    ;
    var parsed = try std.json.parseFromSlice(ApiConfigJson, gpa, minimal, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.schema_version);
    var owned = try dupeJsonToOwned(gpa, parsed.value);
    defer owned.deinit(gpa);
    try std.testing.expectEqualStrings("openai_compat", owned.provider);
}
