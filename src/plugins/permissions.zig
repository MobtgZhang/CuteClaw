//! 插件权限：按插件 id 授予能力，工具执行前统一校验。

const std = @import("std");
const sandbox = @import("../sandbox/policy.zig");

const Allocator = std.mem.Allocator;

pub const PermissionError = error{ CapabilityDenied, OutOfMemory };

pub const Permissions = struct {
    gpa: Allocator,
    grants: std.StringHashMap(std.EnumSet(sandbox.Capability)),

    pub fn init(gpa: Allocator) Permissions {
        return .{ .gpa = gpa, .grants = std.StringHashMap(std.EnumSet(sandbox.Capability)).init(gpa) };
    }

    pub fn deinit(self: *Permissions) void {
        var it = self.grants.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.grants.deinit();
    }

    pub fn grant(self: *Permissions, plugin_id: []const u8, cap: sandbox.Capability) !void {
        const entry = try self.grants.getOrPut(plugin_id);
        if (!entry.found_existing) {
            const key = try self.gpa.dupe(u8, plugin_id);
            entry.key_ptr.* = key;
            entry.value_ptr.* = std.EnumSet(sandbox.Capability){};
        }
        entry.value_ptr.insert(cap);
    }

    pub fn grantNames(self: *Permissions, plugin_id: []const u8, names: []const []const u8) !void {
        for (names) |n| {
            const cap = sandbox.capabilityFromString(n) orelse continue;
            try self.grant(plugin_id, cap);
        }
    }

    pub fn allows(self: *Permissions, plugin_id: []const u8, cap: sandbox.Capability) bool {
        const set = self.grants.get(plugin_id) orelse return false;
        return set.contains(cap);
    }

    pub fn check(self: *Permissions, plugin_id: []const u8, cap: sandbox.Capability) PermissionError!void {
        if (!self.allows(plugin_id, cap)) return error.CapabilityDenied;
    }

    pub fn pluginCount(self: *Permissions) usize {
        return self.grants.count();
    }
};

test "plugin permissions" {
    const gpa = std.testing.allocator;
    var perms = Permissions.init(gpa);
    defer perms.deinit();

    try perms.grantNames("pcb-layout", &.{ "run_tool", "design_edit" });
    try perms.check("pcb-layout", .run_tool);
    try std.testing.expectError(error.CapabilityDenied, perms.check("other", .run_tool));
    try std.testing.expectEqual(@as(usize, 1), perms.pluginCount());
}
