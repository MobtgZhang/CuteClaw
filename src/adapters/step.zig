//! STEP（ISO-10303-21）摘要：实体计数、包围盒与外壳配合检查。不依赖外部 CAD 运行。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const geometry = @import("../design/geometry.zig");
const pcb = @import("../design/pcb.zig");
const project = @import("../design/project.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = error{ NoDataSection, MalformedEntity };

pub const Header = struct {
    file_description: []const u8,
    file_name: []const u8,
    application: []const u8,
};

pub const Summary = struct {
    gpa: Allocator,
    header: Header,
    entity_count: usize,
    counts: std.StringHashMap(usize),
    bbox: geometry.Rect,
    solids: usize,
    shells: usize,

    pub fn deinit(self: *Summary) void {
        gpa_free_header(self.gpa, &self.header);
        var it = self.counts.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.counts.deinit();
    }

    pub fn countOf(self: *const Summary, entity_type: []const u8) usize {
        return self.counts.get(entity_type) orelse 0;
    }

    pub fn toJson(self: *const Summary) !std.json.Value {
        var obj = ju.newObj(self.gpa);
        try ju.putKey(self.gpa, &obj.object, "file_name", try ju.strVal(self.gpa, self.header.file_name));
        try ju.putKey(self.gpa, &obj.object, "entity_count", .{ .integer = @intCast(self.entity_count) });
        try ju.putKey(self.gpa, &obj.object, "solids", .{ .integer = @intCast(self.solids) });
        try ju.putKey(self.gpa, &obj.object, "shells", .{ .integer = @intCast(self.shells) });
        try ju.putKey(self.gpa, &obj.object, "width", .{ .float = self.bbox.width() });
        try ju.putKey(self.gpa, &obj.object, "height", .{ .float = self.bbox.height() });
        var map = ju.newObj(self.gpa);
        var it = self.counts.iterator();
        while (it.next()) |e| try ju.putKey(self.gpa, &map.object, e.key_ptr.*, .{ .integer = @intCast(e.value_ptr.*) });
        try ju.putKey(self.gpa, &obj.object, "counts", map);
        return obj;
    }
};

fn gpa_free_header(gpa: Allocator, header: *Header) void {
    gpa.free(header.file_description);
    gpa.free(header.file_name);
    gpa.free(header.application);
}

pub fn parse(gpa: Allocator, text: []const u8) !Summary {
    var summary = Summary{
        .gpa = gpa,
        .header = .{
            .file_description = try gpa.dupe(u8, ""),
            .file_name = try gpa.dupe(u8, ""),
            .application = try gpa.dupe(u8, ""),
        },
        .entity_count = 0,
        .counts = std.StringHashMap(usize).init(gpa),
        .bbox = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 0, .y = 0 } },
        .solids = 0,
        .shells = 0,
    };
    errdefer summary.deinit();

    var in_data = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (!in_data) {
            if (std.mem.startsWith(u8, trimmed, "FILE_NAME")) {
                summary.header.file_name = try gpa.dupe(u8, quotedField(trimmed));
            } else if (std.mem.startsWith(u8, trimmed, "FILE_DESCRIPTION")) {
                summary.header.file_description = try gpa.dupe(u8, quotedField(trimmed));
            } else if (std.mem.startsWith(u8, trimmed, "APPLICATION")) {
                summary.header.application = try gpa.dupe(u8, quotedField(trimmed));
            } else if (std.mem.eql(u8, trimmed, "DATA;")) {
                in_data = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "ENDSEC;") or std.mem.eql(u8, trimmed, "END-ISO-10303-21;")) break;
        if (!std.mem.startsWith(u8, trimmed, "#")) continue;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.MalformedEntity;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.MalformedEntity;
        const entity_type = std.mem.trim(u8, trimmed[eq + 1 .. open], " ");
        if (entity_type.len == 0) return error.MalformedEntity;

        summary.entity_count += 1;
        // getOrPut 不会插入已存在的 key：必须释放自己 dupe 出来的那份，
        // 否则 deinit 会对同一个 key 二次释放。
        const key = try gpa.dupe(u8, entity_type);
        const entry = try summary.counts.getOrPut(key);
        if (entry.found_existing) {
            gpa.free(key);
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }

        if (std.mem.eql(u8, entity_type, "MANIFOLD_SOLID_BREP")) summary.solids += 1;
        if (std.mem.eql(u8, entity_type, "CLOSED_SHELL")) summary.shells += 1;

        if (std.mem.eql(u8, entity_type, "CARTESIAN_POINT")) {
            const args = trimmed[open + 1 ..];
            var nums: std.ArrayList(f64) = .empty;
            defer nums.deinit(
                gpa,
            );
            var parts = std.mem.splitScalar(u8, args, ',');
            while (parts.next()) |part| {
                var token = std.mem.trim(u8, part, " );\t'");
                if (token.len == 0) continue;
                // 第一个逗号前是实体名引号加坐标组的开头（例如 #2 的 "('',(45.0"），
                // 只取最后一个 '(' 之后的片段才是真正的坐标值。
                if (std.mem.lastIndexOfScalar(u8, token, '(')) |idx| token = token[idx + 1 ..];
                if (token.len == 0) continue;
                const value = std.fmt.parseFloat(f64, token) catch continue;
                try nums.append(gpa, value);
            }
            if (nums.items.len >= 2) {
                const x = nums.items[0];
                const y = nums.items[1];
                if (summary.entity_count == 1) {
                    summary.bbox = .{ .min = .{ .x = x, .y = y }, .max = .{ .x = x, .y = y } };
                } else {
                    if (x < summary.bbox.min.x) summary.bbox.min.x = x;
                    if (y < summary.bbox.min.y) summary.bbox.min.y = y;
                    if (x > summary.bbox.max.x) summary.bbox.max.x = x;
                    if (y > summary.bbox.max.y) summary.bbox.max.y = y;
                }
            }
        }
    }

    if (!in_data) return error.NoDataSection;
    return summary;
}

fn quotedField(line: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, line, '\'') orelse return "";
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '\'') orelse return rest;
    return rest[0..second];
}

/// STEP 包围盒与 PCB 板框的配合检查（厚度方向按外壳高度近似）。
pub fn fitsBoard(summary: *const Summary, board: *const pcb.Board, min_clearance: f64) bool {
    if (summary.entity_count == 0) return false;
    const cavity = geometry.Rect{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = summary.bbox.width() - min_clearance * 2.0, .y = summary.bbox.height() - min_clearance * 2.0 },
    };
    return cavity.containsRect(board.bounds);
}

test "step summary" {
    const gpa = std.testing.allocator;
    const text =
        \\ISO-10303-21;
        \\FILE;
        \\FILE_DESCRIPTION(('shell v2'),'2;1');
        \\FILE_NAME('enclosure.step','2026-10-26T00:00:00',('cuteclaw'),(''),'automotive','');
        \\APPLICATION('CUTECLAW');
        \\ENDSEC;
        \\DATA;
        \\#1 = CARTESIAN_POINT('',(0.0,0.0,0.0));
        \\#2 = CARTESIAN_POINT('',(45.0,35.0,12.0));
        \\#3 = CLOSED_SHELL('',(#1,#2));
        \\#4 = MANIFOLD_SOLID_BREP('shell',#3);
        \\#5 = CARTESIAN_POINT('',(20.0,15.0,0.0));
        \\ENDSEC;
        \\END-ISO-10303-21;
    ;

    var summary = try parse(gpa, text);
    defer summary.deinit();

    try std.testing.expectEqualStrings("enclosure.step", summary.header.file_name);
    try std.testing.expectEqual(@as(usize, 5), summary.entity_count);
    try std.testing.expectEqual(@as(usize, 3), summary.countOf("CARTESIAN_POINT"));
    try std.testing.expectEqual(@as(usize, 1), summary.solids);
    try std.testing.expectEqual(@as(usize, 1), summary.shells);
    try std.testing.expectApproxEqAbs(@as(f64, 45.0), summary.bbox.width(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 35.0), summary.bbox.height(), 0.0001);

    var board = try pcb.Board.init(gpa, "fit");
    defer board.deinit();
    board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 40, .y = 30 } };
    try std.testing.expect(fitsBoard(&summary, &board, 1.0));

    board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 60, .y = 30 } };
    try std.testing.expect(!fitsBoard(&summary, &board, 1.0));

    const json = try summary.toJson();
    defer ju.freeJsonValue(gpa, json);
    const rendered = try ju.stringifyAlloc(gpa, json);
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"entity_count\":5") != null);
}

test "step without data section" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NoDataSection, parse(gpa, "ISO-10303-21;\nFILE;\nENDSEC;\n"));
}
