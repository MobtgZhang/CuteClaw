//! 权限与沙箱：能力开关 + 工作区路径边界。控制平面在 Zig 内，外部工具进程仍受此策略约束。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Capability = enum {
    read_file,
    write_file,
    run_tool,
    network,
    plugin_exec,
    design_edit,
    evolve_write,
};

pub fn capabilityFromString(s: []const u8) ?Capability {
    if (std.mem.eql(u8, s, "read_file")) return .read_file;
    if (std.mem.eql(u8, s, "write_file")) return .write_file;
    if (std.mem.eql(u8, s, "run_tool")) return .run_tool;
    if (std.mem.eql(u8, s, "network")) return .network;
    if (std.mem.eql(u8, s, "plugin_exec")) return .plugin_exec;
    if (std.mem.eql(u8, s, "design_edit")) return .design_edit;
    if (std.mem.eql(u8, s, "evolve_write")) return .evolve_write;
    return null;
}

pub const PolicyError = error{
    CapabilityDenied,
    PathOutsideWorkspace,
    PathDenied,
    OutOfMemory,
};

pub const Policy = struct {
    gpa: Allocator,
    allowed: std.EnumSet(Capability),
    workspace_root: []const u8,
    denied_paths: []const []const u8,

    pub fn init(gpa: Allocator, workspace_root: []const u8) Policy {
        return .{
            .gpa = gpa,
            .allowed = std.EnumSet(Capability){},
            .workspace_root = workspace_root,
            .denied_paths = &.{},
        };
    }

    pub fn grant(self: *Policy, cap: Capability) !void {
        self.allowed.insert(cap);
    }

    pub fn allows(self: *const Policy, cap: Capability) bool {
        return self.allowed.contains(cap);
    }

    pub fn checkCapability(self: *const Policy, cap: Capability) PolicyError!void {
        if (!self.allows(cap)) return error.CapabilityDenied;
    }

    /// 解析后的路径必须落在工作区内，且不在显式拒绝列表内。
    pub fn checkPath(self: *const Policy, path: []const u8) PolicyError!void {
        try self.checkCapability(.read_file);
        const abs = try self.resolve(path);
        defer self.gpa.free(abs);
        for (self.denied_paths) |d| {
            if (std.mem.eql(u8, abs, d)) return error.PathDenied;
        }
        const root = try self.absoluteRoot();
        defer self.gpa.free(root);
        if (root.len == 0) return;
        if (!std.mem.startsWith(u8, abs, root)) return error.PathOutsideWorkspace;
    }

    /// 工作区根必须解析成绝对路径：相对工作区（含默认 "."）以当前目录为基准。
    fn absoluteRoot(self: *const Policy) ![]const u8 {
        if (std.fs.path.isAbsolute(self.workspace_root)) return self.gpa.dupe(u8, self.workspace_root);
        const trimmed = std.mem.trim(u8, self.workspace_root, "/");
        // 无法解析当前目录时按最小权限处理：宁可拒绝，也不放行越界路径。
        const cwd = std.fs.cwd().realpathAlloc(self.gpa, ".") catch return error.PathOutsideWorkspace;
        defer self.gpa.free(cwd);
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return self.gpa.dupe(u8, cwd);
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ cwd, trimmed });
    }

    fn resolve(self: *const Policy, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return self.gpa.dupe(u8, path);
        const root = try self.absoluteRoot();
        defer self.gpa.free(root);
        if (root.len == 0) return self.gpa.dupe(u8, path);
        if (std.mem.eql(u8, path, ".")) return self.gpa.dupe(u8, root);
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ root, path });
    }
};

test "capability grant" {
    const gpa = std.testing.allocator;
    var p = Policy.init(gpa, "workspace");
    try p.grant(.read_file);
    try std.testing.expect(p.allows(.read_file));
    try std.testing.expect(!p.allows(.network));
    try p.checkCapability(.read_file);
    try std.testing.expectError(error.CapabilityDenied, p.checkCapability(.plugin_exec));
    try std.testing.expectEqual(Capability.design_edit, capabilityFromString("design_edit").?);
    try std.testing.expect(capabilityFromString("nope") == null);
}

test "path boundary" {
    const gpa = std.testing.allocator;
    var p = Policy.init(gpa, "/tmp/ws");
    try p.grant(.read_file);
    try p.checkPath("pcb/board.kicad_pcb");
    try std.testing.expectError(error.PathOutsideWorkspace, p.checkPath("/etc/passwd"));
}

test "相对工作区以当前目录为基准" {
    const gpa = std.testing.allocator;
    var p = Policy.init(gpa, ".");
    try p.grant(.read_file);
    const cwd = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(cwd);
    const inside = try std.fmt.allocPrint(gpa, "{s}/board.kicad_pcb", .{cwd});
    defer gpa.free(inside);
    try p.checkPath(inside);
    try p.checkPath("benchmarks/pcb/board.kicad_pcb");
    try std.testing.expectError(error.PathOutsideWorkspace, p.checkPath("/etc/passwd"));
}
