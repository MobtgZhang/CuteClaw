//! PCB 数据模型：板框、器件、焊盘、网络与飞线（每网络最小生成树长度）。

const std = @import("std");
const geometry = @import("geometry.zig");

const Allocator = std.mem.Allocator;

pub const Pad = struct {
    component: []const u8,
    net: []const u8,
    pos: geometry.Point,
};

pub const Net = struct {
    name: []const u8,
    pads: []const Pad,

    /// 该网络飞线长度：对焊盘求最小生成树（Prim，O(n^2)）。
    pub fn ratLength(self: Net, gpa: Allocator) !f64 {
        const n = self.pads.len;
        if (n < 2) return 0.0;

        var visited = std.ArrayList(bool).empty;
        defer visited.deinit(
            gpa,
        );
        var min_dist = std.ArrayList(f64).empty;
        defer min_dist.deinit(
            gpa,
        );

        for (0..n) |i| {
            try visited.append(gpa, false);
            try min_dist.append(gpa, if (i == 0) 0.0 else std.math.inf(f64));
        }

        var total: f64 = 0.0;
        var picked: usize = 0;
        while (picked < n) {
            var best: usize = 0;
            var best_dist: f64 = std.math.inf(f64);
            var i: usize = 0;
            while (i < n) {
                if (!visited.items[i] and min_dist.items[i] < best_dist) {
                    best_dist = min_dist.items[i];
                    best = i;
                }
                i += 1;
            }
            visited.items[best] = true;
            picked += 1;
            total += best_dist;
            var j: usize = 0;
            while (j < n) {
                if (!visited.items[j]) {
                    const d = self.pads[best].pos.distanceTo(self.pads[j].pos);
                    if (d < min_dist.items[j]) min_dist.items[j] = d;
                }
                j += 1;
            }
        }
        return total;
    }
};

pub const Component = struct {
    ref: []const u8,
    footprint: []const u8,
    center: geometry.Point,
    rotation_deg: f64,
    width: f64,
    height: f64,
    courtyard_margin: f64,

    pub fn courtyard(self: Component) geometry.Rect {
        return geometry.rectFromCenter(self.center, self.width, self.height, self.rotation_deg).expand(self.courtyard_margin);
    }
};

pub const Hole = struct {
    ref: []const u8,
    pos: geometry.Point,
    diameter: f64,
};

pub const Board = struct {
    gpa: Allocator,
    name: []const u8,
    bounds: geometry.Rect,
    trace_width: f64,
    components: std.ArrayList(Component),
    pads: std.ArrayList(Pad),
    holes: std.ArrayList(Hole),

    pub fn init(gpa: Allocator, name: []const u8) !Board {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 0, .y = 0 } },
            .trace_width = 0.2,
            .components = .empty,
            .pads = .empty,
            .holes = .empty,
        };
    }

    pub fn deinit(self: *Board) void {
        self.gpa.free(self.name);
        for (self.components.items) |c| {
            self.gpa.free(c.ref);
            self.gpa.free(c.footprint);
        }
        self.components.deinit(self.gpa);
        for (self.pads.items) |p| {
            self.gpa.free(p.component);
            self.gpa.free(p.net);
        }
        self.pads.deinit(self.gpa);
        for (self.holes.items) |h| self.gpa.free(h.ref);
        self.holes.deinit(self.gpa);
    }

    pub fn addComponent(self: *Board, comp: Component) !void {
        try self.components.append(self.gpa, .{
            .ref = try self.gpa.dupe(u8, comp.ref),
            .footprint = try self.gpa.dupe(u8, comp.footprint),
            .center = comp.center,
            .rotation_deg = comp.rotation_deg,
            .width = comp.width,
            .height = comp.height,
            .courtyard_margin = comp.courtyard_margin,
        });
    }

    pub fn addPad(self: *Board, pad: Pad) !void {
        try self.pads.append(self.gpa, .{
            .component = try self.gpa.dupe(u8, pad.component),
            .net = try self.gpa.dupe(u8, pad.net),
            .pos = pad.pos,
        });
    }

    pub fn addHole(self: *Board, hole: Hole) !void {
        try self.holes.append(self.gpa, .{
            .ref = try self.gpa.dupe(u8, hole.ref),
            .pos = hole.pos,
            .diameter = hole.diameter,
        });
    }

    /// 按网络分组焊盘；返回切片由调用方释放（内部字符串仍归 Board 所有）。
    pub fn netGroups(self: *const Board) ![]Net {
        var order: std.ArrayList([]const u8) = .empty;
        defer order.deinit(
            self.gpa,
        );
        var groups = std.StringHashMap(std.ArrayList(Pad)).init(self.gpa);
        defer {
            var it = groups.iterator();
            while (it.next()) |e| e.value_ptr.deinit(self.gpa);
            groups.deinit();
        }

        for (self.pads.items) |p| {
            const entry = try groups.getOrPut(p.net);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
                try order.append(self.gpa, p.net);
            }
            try entry.value_ptr.append(self.gpa, p);
        }

        var out: std.ArrayList(Net) = .empty;
        errdefer out.deinit(
            self.gpa,
        );
        for (order.items) |name| {
            const list = groups.get(name) orelse continue;
            const pads = try self.gpa.alloc(Pad, list.items.len);
            errdefer self.gpa.free(pads);
            for (list.items, 0..) |pad, i| pads[i] = pad;
            try out.append(self.gpa, .{ .name = name, .pads = pads });
        }
        return out.toOwnedSlice(
            self.gpa,
        );
    }

    pub fn freeNets(gpa: Allocator, nets: []Net) void {
        for (nets) |n| gpa.free(n.pads);
        gpa.free(nets);
    }

    pub fn totalRatLength(self: *const Board) !f64 {
        const groups = try self.netGroups();
        defer freeNets(self.gpa, groups);
        var total: f64 = 0.0;
        for (groups) |n| total += try n.ratLength(self.gpa);
        return total;
    }

    /// 器件是否落在板框内（按 courtyard 包围盒判断）。
    pub fn fitsComponent(self: *const Board, comp: Component) bool {
        return self.bounds.containsRect(comp.courtyard());
    }
};

test "board nets and rat length" {
    const gpa = std.testing.allocator;
    var board = try Board.init(gpa, "demo");
    defer board.deinit();

    board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 50, .y = 40 } };
    try board.addComponent(.{
        .ref = "U1",
        .footprint = "Package_QFP:LQFP-32_7x7mm",
        .center = .{ .x = 10, .y = 10 },
        .rotation_deg = 0,
        .width = 7,
        .height = 7,
        .courtyard_margin = 0.25,
    });

    try board.addPad(.{ .component = "U1", .net = "GND", .pos = .{ .x = 10, .y = 10 } });
    try board.addPad(.{ .component = "C1", .net = "GND", .pos = .{ .x = 13, .y = 10 } });
    try board.addPad(.{ .component = "C2", .net = "GND", .pos = .{ .x = 13, .y = 14 } });
    try board.addPad(.{ .component = "J1", .net = "VBUS", .pos = .{ .x = 40, .y = 20 } });
    try board.addHole(.{ .ref = "H1", .pos = .{ .x = 2, .y = 2 }, .diameter = 3.2 });

    const groups = try board.netGroups();
    defer Board.freeNets(gpa, groups);
    try std.testing.expectEqual(@as(usize, 2), groups.len);

    var gnd: ?Net = null;
    for (groups) |n| {
        if (std.mem.eql(u8, n.name, "GND")) gnd = n;
    }
    const g = gnd orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), g.pads.len);
    // MST: 3 + 4 = 7（10,10 -> 13,10 -> 13,14）
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), try g.ratLength(gpa), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), try board.totalRatLength(), 0.0001);

    try std.testing.expect(board.bounds.containsRect(board.components.items[0].courtyard()));
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), board.holes.items[0].diameter, 0.0001);
}
