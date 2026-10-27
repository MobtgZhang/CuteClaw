//! 设计工程：需求、约束、PCB 与外壳产物，以及可序列化的版本记录。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const geometry = @import("geometry.zig");
const pcb = @import("pcb.zig");
const constraints = @import("constraints.zig");

const Allocator = std.mem.Allocator;

pub const Artifact = struct {
    path: []const u8,
    kind: []const u8,
    version: []const u8,

    pub fn free(self: *const Artifact, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.kind);
        gpa.free(self.version);
    }
};

pub const Enclosure = struct {
    name: []const u8,
    outer: geometry.Rect,
    wall: f64,
    height: f64,

    pub fn cavity(self: *const Enclosure) geometry.Rect {
        return self.outer.expand(-self.wall);
    }

    /// 外壳腔体与 PCB 板框之间的最小间隙（负值表示干涉）。
    /// 四条边都要用「腔体内壁 - 板框外缘」的同一朝向，否则 min 角会把间隙算成负数。
    pub fn fitClearance(self: *const Enclosure, board: *const pcb.Board) f64 {
        const c = self.cavity();
        const gap_x = @min(board.bounds.min.x - c.min.x, c.max.x - board.bounds.max.x);
        const gap_y = @min(board.bounds.min.y - c.min.y, c.max.y - board.bounds.max.y);
        return @min(gap_x, gap_y);
    }

    pub fn fitsBoard(self: *const Enclosure, board: *const pcb.Board) bool {
        return self.fitClearance(board) >= 0.0;
    }
};

pub const DesignProject = struct {
    gpa: Allocator,
    id: []const u8,
    name: []const u8,
    requirements: std.StringHashMap([]const u8),
    constraints: constraints.ConstraintSet,
    board: pcb.Board,
    enclosure: ?Enclosure = null,
    artifacts: std.ArrayList(Artifact),

    pub fn init(gpa: Allocator, id: []const u8, name: []const u8) !DesignProject {
        return .{
            .gpa = gpa,
            .id = try gpa.dupe(u8, id),
            .name = try gpa.dupe(u8, name),
            .requirements = std.StringHashMap([]const u8).init(gpa),
            .constraints = constraints.ConstraintSet.init(gpa),
            .board = try pcb.Board.init(gpa, name),
            .artifacts = .empty,
        };
    }

    pub fn deinit(self: *DesignProject) void {
        self.gpa.free(self.id);
        self.gpa.free(self.name);
        var it = self.requirements.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.requirements.deinit();
        self.constraints.deinit();
        self.board.deinit();
        if (self.enclosure) |enc| self.gpa.free(enc.name);
        for (self.artifacts.items) |a| a.free(self.gpa);
        self.artifacts.deinit(
            self.gpa,
        );
    }

    pub fn setRequirement(self: *DesignProject, key: []const u8, value: []const u8) !void {
        if (self.requirements.get(key)) |old| self.gpa.free(old);
        try self.requirements.put(try self.gpa.dupe(u8, key), try self.gpa.dupe(u8, value));
    }

    pub fn addArtifact(self: *DesignProject, path: []const u8, kind: []const u8, version: []const u8) !void {
        try self.artifacts.append(self.gpa, .{
            .path = try self.gpa.dupe(u8, path),
            .kind = try self.gpa.dupe(u8, kind),
            .version = try self.gpa.dupe(u8, version),
        });
    }

    pub fn setEnclosure(self: *DesignProject, enc: Enclosure) !void {
        if (self.enclosure) |old| self.gpa.free(old.name);
        self.enclosure = .{
            .name = try self.gpa.dupe(u8, enc.name),
            .outer = enc.outer,
            .wall = enc.wall,
            .height = enc.height,
        };
    }

    pub fn toJson(self: *DesignProject) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "id", try ju.strVal(self.gpa, self.id));
        try ju.putKey(self.gpa, &obj.object, "name", try ju.strVal(self.gpa, self.name));

        var req = ju.newObj(self.gpa);
        var it = self.requirements.iterator();
        while (it.next()) |e| try ju.putKey(self.gpa, &req.object, e.key_ptr.*, try ju.strVal(self.gpa, e.value_ptr.*));
        try ju.putKey(self.gpa, &obj.object, "requirements", req);

        var rules = ju.newArr(self.gpa);
        for (self.constraints.rules.items) |r| {
            var item = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &item.object, "id", try ju.strVal(self.gpa, r.id));
            try ju.putKey(self.gpa, &item.object, "kind", try ju.strVal(self.gpa, @tagName(r.kind)));
            try ju.putKey(self.gpa, &item.object, "limit", .{ .float = r.limit });
            try ju.putKey(self.gpa, &item.object, "direction", try ju.strVal(self.gpa, @tagName(r.direction)));
            try ju.putKey(self.gpa, &item.object, "severity", try ju.strVal(self.gpa, @tagName(r.severity)));
            try rules.array.append(item);
        }
        try ju.putKey(self.gpa, &obj.object, "constraints", rules);

        var board = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &board.object, "name", try ju.strVal(self.gpa, self.board.name));
        try ju.putKey(self.gpa, &board.object, "trace_width", .{ .float = self.board.trace_width });
        try ju.putKey(self.gpa, &board.object, "width", .{ .float = self.board.bounds.width() });
        try ju.putKey(self.gpa, &board.object, "height", .{ .float = self.board.bounds.height() });
        try ju.putKey(self.gpa, &board.object, "origin", originValue(self.gpa, self.board.bounds.min));
        try ju.putKey(self.gpa, &board.object, "components", .{ .integer = @intCast(self.board.components.items.len) });
        try ju.putKey(self.gpa, &board.object, "pads", .{ .integer = @intCast(self.board.pads.items.len) });
        try ju.putKey(self.gpa, &board.object, "holes", .{ .integer = @intCast(self.board.holes.items.len) });
        try ju.putKey(self.gpa, &board.object, "rat_length", .{ .float = try self.board.totalRatLength() });
        try ju.putKey(self.gpa, &obj.object, "board", board);

        if (self.enclosure) |enc| {
            var e = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &e.object, "name", try ju.strVal(self.gpa, enc.name));
            try ju.putKey(self.gpa, &e.object, "width", .{ .float = enc.outer.width() });
            try ju.putKey(self.gpa, &e.object, "height", .{ .float = enc.outer.height() });
            try ju.putKey(self.gpa, &e.object, "origin", originValue(self.gpa, enc.outer.min));
            try ju.putKey(self.gpa, &e.object, "wall", .{ .float = enc.wall });
            try ju.putKey(self.gpa, &e.object, "shell_height", .{ .float = enc.height });
            try ju.putKey(self.gpa, &e.object, "fit_clearance", .{ .float = enc.fitClearance(&self.board) });
            try ju.putKey(self.gpa, &obj.object, "enclosure", e);
        }

        var arts = ju.newArr(self.gpa);
        for (self.artifacts.items) |a| {
            var item = ju.newObj(self.gpa);
            try ju.putKey(self.gpa, &item.object, "path", try ju.strVal(self.gpa, a.path));
            try ju.putKey(self.gpa, &item.object, "kind", try ju.strVal(self.gpa, a.kind));
            try ju.putKey(self.gpa, &item.object, "version", try ju.strVal(self.gpa, a.version));
            try arts.array.append(item);
        }
        try ju.putKey(self.gpa, &obj.object, "artifacts", arts);

        return obj;
    }

    /// 从 JSON 文本恢复工程（几何仅保留板框与外壳外形）。
    pub fn fromJson(gpa: Allocator, text: []const u8) !DesignProject {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.MalformedJson,
        };

        var project = try DesignProject.init(gpa, ju.objStr(root, "id"), ju.objStr(root, "name"));
        errdefer project.deinit();

        if (ju.objGet(root, "requirements")) |req_v| {
            if (req_v == .object) {
                var it = req_v.object.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* != .string) continue;
                    try project.setRequirement(e.key_ptr.*, e.value_ptr.string);
                }
            }
        }

        if (ju.objGet(root, "constraints")) |rules_v| {
            if (rules_v == .array) {
                for (rules_v.array.items) |rv| {
                    if (rv != .object) continue;
                    const kind = std.meta.stringToEnum(constraints.Kind, ju.objStr(rv.object, "kind")) orelse continue;
                    const direction = constraints.directionFromString(ju.objStr(rv.object, "direction")) orelse .min;
                    const severity = constraints.severityFromString(ju.objStr(rv.object, "severity")) orelse .hard;
                    try project.constraints.add(.{
                        .id = ju.objStr(rv.object, "id"),
                        .kind = kind,
                        .limit = numberValue(rv.object, "limit"),
                        .direction = direction,
                        .severity = severity,
                    });
                }
            }
        }

        if (ju.objGet(root, "board")) |board_v| {
            if (board_v == .object) {
                const w = numberValue(board_v.object, "width");
                const h = numberValue(board_v.object, "height");
                const origin = originFromJson(board_v.object);
                project.board.bounds = .{
                    .min = origin,
                    .max = .{ .x = origin.x + w, .y = origin.y + h },
                };
                project.board.trace_width = numberValue(board_v.object, "trace_width");
            }
        }

        if (ju.objGet(root, "enclosure")) |enc_v| {
            if (enc_v == .object) {
                const w = numberValue(enc_v.object, "width");
                const h = numberValue(enc_v.object, "height");
                const wall = numberValue(enc_v.object, "wall");
                const shell_height = numberValue(enc_v.object, "shell_height");
                const origin = originFromJson(enc_v.object);
                try project.setEnclosure(.{
                    .name = ju.objStr(enc_v.object, "name"),
                    .outer = .{ .min = origin, .max = .{ .x = origin.x + w, .y = origin.y + h } },
                    .wall = wall,
                    .height = shell_height,
                });
            }
        }

        if (ju.objGet(root, "artifacts")) |arts_v| {
            if (arts_v == .array) {
                for (arts_v.array.items) |av| {
                    if (av != .object) continue;
                    try project.addArtifact(ju.objStr(av.object, "path"), ju.objStr(av.object, "kind"), ju.objStr(av.object, "version"));
                }
            }
        }

        return project;
    }
};

/// 几何定位原点：fit check 依赖板框与腔体的相对位置，roundtrip 必须保留它。
fn originValue(gpa: Allocator, p: geometry.Point) std.json.Value {
    var obj = ju.newObj(gpa);
    ju.putKey(gpa, &obj.object, "x", .{ .float = p.x }) catch return .null;
    ju.putKey(gpa, &obj.object, "y", .{ .float = p.y }) catch return .null;
    return obj;
}

fn originFromJson(obj: std.json.ObjectMap) geometry.Point {
    const v = ju.objGet(obj, "origin") orelse return .{ .x = 0, .y = 0 };
    if (v != .object) return .{ .x = 0, .y = 0 };
    return .{ .x = numberValue(v.object, "x"), .y = numberValue(v.object, "y") };
}

fn numberValue(obj: std.json.ObjectMap, key: []const u8) f64 {
    const v = ju.objGet(obj, key) orelse return 0.0;
    switch (v) {
        .integer => |i| return @floatFromInt(i),
        .float => |f| return f,
        else => return 0.0,
    }
}

test "project json roundtrip" {
    const gpa = std.testing.allocator;
    var project = try DesignProject.init(gpa, "p1", "sensor-node");
    defer project.deinit();

    try project.setRequirement("enclosure", "keep USB-C cutout");
    try project.constraints.add(.{ .id = "min_trace_width", .kind = .trace_width, .limit = 0.2, .direction = .min, .severity = .hard });
    // 板框必须整体落在腔体内（腔体 = 外壳外轮廓向内缩一个壁厚），否则 fitClearance 为负。
    project.board.bounds = .{ .min = .{ .x = 4, .y = 4 }, .max = .{ .x = 44, .y = 34 } };
    project.board.trace_width = 0.25;
    try project.setEnclosure(.{
        .name = "shell",
        .outer = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 48, .y = 38 } },
        .wall = 2.0,
        .height = 12,
    });
    try project.addArtifact("out/board.kicad_pcb", "kicad_pcb", "0.3");

    try std.testing.expect(project.enclosure.?.fitsBoard(&project.board));

    const json = try project.toJson();
    defer ju.freeJsonValue(gpa, json);
    const text = try ju.stringifyAlloc(gpa, json);
    defer gpa.free(text);

    var restored = try DesignProject.fromJson(gpa, text);
    defer restored.deinit();
    try std.testing.expectEqualStrings("sensor-node", restored.name);
    try std.testing.expectEqualStrings("keep USB-C cutout", restored.requirements.get("enclosure").?);
    try std.testing.expectEqual(@as(usize, 1), restored.constraints.count());
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), restored.board.bounds.width(), 0.0001);
    try std.testing.expectEqual(@as(usize, 1), restored.artifacts.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), restored.enclosure.?.fitClearance(&restored.board), 0.0001);
}
