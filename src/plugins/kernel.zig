//! 插件内核：加载清单、授予能力、登记可撤销效果，并把插件工具接入统一注册表。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const events = @import("../core/events.zig");
const tools = @import("../core/tools.zig");
const manifest = @import("manifest.zig");
const permissions = @import("permissions.zig");
const effects = @import("registry.zig");

const Allocator = std.mem.Allocator;

pub const PluginRecord = struct {
    id: []const u8,
    root: []const u8,
    manifest: manifest.PluginManifest,
    enabled: bool,

    pub fn free(self: *const PluginRecord, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.root);
        self.manifest.free(gpa);
    }
};

pub const Kernel = struct {
    gpa: Allocator,
    registry: *tools.Registry,
    perms: permissions.Permissions,
    effects: effects.EffectRegistry,
    plugins: std.ArrayList(PluginRecord),
    bus: ?*events.EventBus = null,

    pub fn init(gpa: Allocator, registry: *tools.Registry) Kernel {
        return .{
            .gpa = gpa,
            .registry = registry,
            .perms = permissions.Permissions.init(gpa),
            .effects = effects.EffectRegistry.init(gpa),
            .plugins = .empty,
        };
    }

    pub fn deinit(self: *Kernel) void {
        for (self.plugins.items) |p| p.free(self.gpa);
        self.plugins.deinit(self.gpa);
        self.effects.deinit();
        self.perms.deinit();
    }

    pub fn load(self: *Kernel, package_json_text: []const u8, root: []const u8) !PluginRecord {
        const m = try manifest.parsePackageJson(self.gpa, package_json_text);
        errdefer m.free(self.gpa);
        const record = PluginRecord{
            .id = try self.gpa.dupe(u8, m.name),
            .root = try self.gpa.dupe(u8, root),
            .manifest = m,
            .enabled = false,
        };
        errdefer record.free(self.gpa);
        try self.plugins.append(self.gpa, record);
        try self.perms.grantNames(record.id, record.manifest.capabilities);
        return record;
    }

    pub fn loadFromPath(self: *Kernel, path: []const u8) !PluginRecord {
        const raw = try std.fs.cwd().readFileAlloc(self.gpa, path, 256 * 1024);
        defer self.gpa.free(raw);
        return self.load(std.mem.trim(u8, raw, " \t\r\n"), std.fs.path.dirname(path) orelse ".");
    }

    pub fn enable(self: *Kernel, id: []const u8) !void {
        const rec = self.find(id) orelse return error.PluginNotFound;
        rec.enabled = true;
        if (self.bus) |bus| {
            const payload = try buildPayload(self.gpa, id, "enabled");
            defer ju.freeJsonValue(self.gpa, payload);
            _ = try bus.dispatch("plugin.enabled", payload, .emit);
        }
    }

    pub fn disable(self: *Kernel, id: []const u8) !void {
        const rec = self.find(id) orelse return error.PluginNotFound;
        if (!rec.enabled) return;
        const rolled = try self.effects.rollback(id);
        _ = rolled;
        rec.enabled = false;
        if (self.bus) |bus| {
            const payload = try buildPayload(self.gpa, id, "disabled");
            defer ju.freeJsonValue(self.gpa, payload);
            _ = try bus.dispatch("plugin.disabled", payload, .emit);
        }
    }

    pub fn find(self: *Kernel, id: []const u8) ?*PluginRecord {
        for (self.plugins.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }

    pub fn enabledCount(self: *Kernel) usize {
        var n: usize = 0;
        for (self.plugins.items) |p| {
            if (p.enabled) n += 1;
        }
        return n;
    }
};

fn buildPayload(gpa: Allocator, id: []const u8, action: []const u8) !std.json.Value {
    var obj = ju.newObj(gpa);
    try ju.putKey(gpa, &obj.object, "plugin", try ju.strVal(gpa, id));
    try ju.putKey(gpa, &obj.object, "action", try ju.strVal(gpa, action));
    return obj;
}

test "kernel load and enable/disable" {
    const gpa = std.testing.allocator;
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    var bus = events.EventBus.init(gpa);
    defer bus.deinit();

    var kernel = Kernel.init(gpa, &reg);
    defer kernel.deinit();
    kernel.bus = &bus;

    const rec = try kernel.load("{\"name\":\"pcb-layout\",\"version\":\"1.0.0\",\"dsh\":{\"manifestVersion\":1},\"capabilities\":[\"run_tool\",\"design_edit\"]}", "skills/pcb-layout");
    try std.testing.expectEqualStrings("pcb-layout", rec.id);
    try std.testing.expect(!rec.enabled);
    try std.testing.expect(kernel.perms.allows("pcb-layout", .design_edit));

    try kernel.enable("pcb-layout");
    try std.testing.expectEqual(@as(usize, 1), kernel.enabledCount());
    try kernel.disable("pcb-layout");
    try std.testing.expectEqual(@as(usize, 0), kernel.enabledCount());
    try std.testing.expectError(error.PluginNotFound, kernel.enable("missing"));
}
