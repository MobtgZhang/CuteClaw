//! DeepSeek Harness（Cordis）插件清单兼容层：`package.json` 的 `dsh` 字段与 `cordis.patch.yml`。
//! 兼容边界锁定 manifestVersion 1；未知字段忽略但保留原始文本供桥接层使用。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");

const Allocator = std.mem.Allocator;

pub const target_manifest_version: u32 = 1;

pub const ManifestError = error{
    MissingName,
    UnsupportedManifestVersion,
    InvalidManifest,
    OutOfMemory,
};

pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    manifest_version: u32,
    bundle: []const u8,
    profile_bundles: []const []const u8,
    client_platform: []const u8,
    client_inject: []const []const u8,
    external: bool,
    engines_dsh: []const u8,
    capabilities: []const []const u8,

    pub fn free(self: *const PluginManifest, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.version);
        gpa.free(self.bundle);
        gpa.free(self.engines_dsh);
        gpa.free(self.client_platform);
        for (self.profile_bundles) |s| gpa.free(s);
        gpa.free(self.profile_bundles);
        for (self.client_inject) |s| gpa.free(s);
        gpa.free(self.client_inject);
        for (self.capabilities) |s| gpa.free(s);
        gpa.free(self.capabilities);
    }
};

pub fn parsePackageJson(gpa: Allocator, text: []const u8) !PluginManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidManifest;
    const root = parsed.value.object;

    const name = ju.objStr(root, "name");
    if (name.len == 0) return error.MissingName;

    var m: PluginManifest = .{
        .name = try gpa.dupe(u8, name),
        .version = try gpa.dupe(u8, ju.objStr(root, "version")),
        .manifest_version = 0,
        .bundle = try gpa.dupe(u8, ""),
        .profile_bundles = &.{},
        .client_platform = try gpa.dupe(u8, ""),
        .client_inject = &.{},
        .external = false,
        .engines_dsh = try gpa.dupe(u8, ""),
        .capabilities = &.{},
    };
    errdefer m.free(gpa);

    if (ju.objGet(root, "dsh")) |dsh_v| {
        if (dsh_v == .object) {
            const dsh = dsh_v.object;
            m.manifest_version = @intCast(ju.objNum(dsh, "manifestVersion"));
            m.bundle = try gpa.dupe(u8, ju.objStr(dsh, "bundle"));
            if (ju.objGet(dsh, "profile")) |p_v| {
                if (p_v == .object) {
                    const profile = p_v.object;
                    if (ju.objGet(profile, "bundles")) |b_v| {
                        if (b_v == .array) {
                            var list: std.ArrayList([]const u8) = .empty;
                            errdefer list.deinit(gpa);
                            for (b_v.array.items) |item| {
                                if (item == .string) try list.append(gpa, try gpa.dupe(u8, item.string));
                            }
                            m.profile_bundles = try list.toOwnedSlice(gpa);
                        }
                    }
                }
            }
            if (ju.objGet(dsh, "client")) |c_v| {
                if (c_v == .object) {
                    const client = c_v.object;
                    m.client_platform = try gpa.dupe(u8, ju.objStr(client, "platform"));
                    if (ju.objGet(client, "inject")) |i_v| {
                        if (i_v == .array) {
                            var list: std.ArrayList([]const u8) = .empty;
                            errdefer list.deinit(gpa);
                            for (i_v.array.items) |item| {
                                if (item == .string) try list.append(gpa, try gpa.dupe(u8, item.string));
                            }
                            m.client_inject = try list.toOwnedSlice(gpa);
                        }
                    }
                    m.external = ju.objGet(client, "external") != null;
                }
            }
        }
    }

    if (m.manifest_version != target_manifest_version) return error.UnsupportedManifestVersion;

    if (ju.objGet(root, "engines")) |e_v| {
        if (e_v == .object) m.engines_dsh = try gpa.dupe(u8, ju.objStr(e_v.object, "dsh"));
    }

    if (ju.objGet(root, "capabilities")) |c_v| {
        if (c_v == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            errdefer list.deinit(gpa);
            for (c_v.array.items) |item| {
                if (item == .string) try list.append(gpa, try gpa.dupe(u8, item.string));
            }
            m.capabilities = try list.toOwnedSlice(gpa);
        }
    }

    return m;
}

/// 最小 semver 判定：支持 `>=x.y.z` 与精确 `x.y.z`，其余按不满足处理。
pub fn semverSatisfies(range: []const u8, version: []const u8) bool {
    if (range.len == 0) return true;
    if (std.mem.startsWith(u8, range, ">=")) {
        const want = std.mem.trim(u8, range[2..], " ");
        return semverCompare(want, version) <= 0;
    }
    return semverCompare(std.mem.trim(u8, range, " "), version) == 0;
}

fn semverCompare(a: []const u8, b: []const u8) i32 {
    const pa = parseSemver(a);
    const pb = parseSemver(b);
    if (pa.major != pb.major) return if (pa.major < pb.major) -1 else 1;
    if (pa.minor != pb.minor) return if (pa.minor < pb.minor) -1 else 1;
    if (pa.patch != pb.patch) return if (pa.patch < pb.patch) -1 else 1;
    return 0;
}

const SemverParts = struct { major: u32, minor: u32, patch: u32 };

fn parseSemver(s: []const u8) SemverParts {
    var parts: SemverParts = .{ .major = 0, .minor = 0, .patch = 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |piece| {
        const n = std.fmt.parseInt(u32, piece, 10) catch 0;
        if (i == 0) parts.major = n;
        if (i == 1) parts.minor = n;
        if (i == 2) parts.patch = n;
        i += 1;
    }
    return parts;
}

pub const PatchEntry = struct {
    id: []const u8,
    plugin: []const u8,
    config: std.json.Value,
    disabled: bool,
};

/// `cordis.patch.yml` 的最小解析：顶层序列 + `key: value`，config 使用 flow（JSON）写法。
pub fn parsePatchYaml(gpa: Allocator, text: []const u8) ![]PatchEntry {
    var out: std.ArrayList(PatchEntry) = .empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(e.id);
            gpa.free(e.plugin);
            ju.freeJsonValue(gpa, e.config);
        }
        out.deinit(gpa);
    }

    var current: ?PatchEntry = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "- ")) {
            if (current) |c| try out.append(gpa, c);
            current = PatchEntry{ .id = "", .plugin = "", .config = .null, .disabled = false };
            const rest = line[2..];
            if (std.mem.indexOfScalar(u8, rest, ':') == null) {
                if (current) |*c| c.plugin = try gpa.dupe(u8, std.mem.trim(u8, rest, "\"'"));
                continue;
            }
        }

        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..sep], " -\t");
        const value = std.mem.trim(u8, line[sep + 1 ..], " \t\"'");
        if (current == null) continue;

        if (std.mem.eql(u8, key, "id")) {
            if (current) |*c| c.id = try gpa.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "plugin")) {
            if (current) |*c| c.plugin = try gpa.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "disabled")) {
            if (current) |*c| c.disabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "config")) {
            if (current) |*c| {
                if (value.len > 0) c.config = try ju.parseValue(gpa, value);
            }
        }
    }
    if (current) |c| try out.append(gpa, c);
    return out.toOwnedSlice(gpa);
}

test "dsh package.json manifest" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"name":"pcb-layout","version":"1.2.0","engines":{"dsh":">=1.0.0"},
        \\ "dsh":{"manifestVersion":1,"bundle":"patch","profile":{"bundles":["core"]},
        \\ "client":{"platform":"node","inject":["tools"],"external":true}},
        \\ "capabilities":["run_tool","design_edit"]}
    ;
    const m = try parsePackageJson(gpa, raw);
    defer m.free(gpa);
    try std.testing.expectEqualStrings("pcb-layout", m.name);
    try std.testing.expectEqual(@as(u32, 1), m.manifest_version);
    try std.testing.expectEqualStrings("patch", m.bundle);
    try std.testing.expectEqual(@as(usize, 1), m.profile_bundles.len);
    try std.testing.expectEqual(@as(usize, 1), m.client_inject.len);
    try std.testing.expect(m.external);
    try std.testing.expectEqual(@as(usize, 2), m.capabilities.len);
    try std.testing.expect(semverSatisfies(m.engines_dsh, "1.4.2"));
    try std.testing.expect(!semverSatisfies(m.engines_dsh, "0.9.0"));
}

test "manifest version gate" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedManifestVersion, parsePackageJson(gpa, "{\"name\":\"x\",\"dsh\":{\"manifestVersion\":2}}"));
    try std.testing.expectError(error.MissingName, parsePackageJson(gpa, "{\"dsh\":{\"manifestVersion\":1}}"));
}

test "cordis patch yaml" {
    const gpa = std.testing.allocator;
    const raw =
        \\# CuteClaw patch
        \\- id: pcb-layout
        \\  plugin: ./skills/pcb-layout
        \\  config: {"max_rounds":6}
        \\- id: enclosure
        \\  plugin: ./skills/enclosure-design
        \\  disabled: true
    ;
    const entries = try parsePatchYaml(gpa, raw);
    defer {
        for (entries) |e| {
            gpa.free(e.id);
            gpa.free(e.plugin);
            ju.freeJsonValue(gpa, e.config);
        }
        gpa.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("pcb-layout", entries[0].id);
    try std.testing.expectEqualStrings("./skills/pcb-layout", entries[0].plugin);
    try std.testing.expect(!entries[0].disabled);
    try std.testing.expectEqual(@as(u64, 6), ju.objNum(entries[0].config.object, "max_rounds"));
    try std.testing.expect(entries[1].disabled);
}
