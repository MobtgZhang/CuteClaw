//! KiCad 适配器：最小 s-expression 解析，读取 `.kicad_pcb` 的器件、焊盘、网络与板框。

const std = @import("std");
const geometry = @import("../design/geometry.zig");
const pcb = @import("../design/pcb.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = error{
    UnexpectedEnd,
    UnbalancedParen,
};

pub const SExp = union(enum) {
    list: []const SExp,
    symbol: []const u8,
    string: []const u8,
    number: f64,
};

pub fn free(gpa: Allocator, node: SExp) void {
    switch (node) {
        .list => |items| {
            for (items) |item| free(gpa, item);
            gpa.free(items);
        },
        .symbol => |s| gpa.free(s),
        .string => |s| gpa.free(s),
        .number => {},
    }
}

const Token = union(enum) {
    open: void,
    close: void,
    symbol: []const u8,
    string: []const u8,
    number: f64,
};

pub fn parse(gpa: Allocator, text: []const u8) !SExp {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    try tokenize(gpa, text, &tokens);

    var index: usize = 0;
    // 已消费的 token 内容所有权转移给 SExp：成功时由调用方 free 释放，
    // 失败时由 parseNode 的 errdefer 释放已构建的子树；未消费的 token 在这里释放。
    errdefer freeTokenPayloads(gpa, tokens.items[index..]);

    const node = try parseNode(gpa, tokens.items, &index);
    if (index != tokens.items.len) {
        free(gpa, node);
        return error.UnbalancedParen;
    }
    return node;
}

fn freeTokenPayloads(gpa: Allocator, tokens: []Token) void {
    for (tokens) |t| switch (t) {
        .symbol => |s| gpa.free(s),
        .string => |s| gpa.free(s),
        else => {},
    };
}

fn tokenize(gpa: Allocator, text: []const u8, out: *std.ArrayList(Token)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '(') {
            try out.append(gpa, .{ .open = {} });
            i += 1;
            continue;
        }
        if (c == ')') {
            try out.append(gpa, .{ .close = {} });
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '"') {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(gpa);
            i += 1;
            while (i < text.len and text[i] != '"') {
                if (text[i] == '\\' and i + 1 < text.len) {
                    try buf.append(gpa, text[i + 1]);
                    i += 2;
                    continue;
                }
                try buf.append(gpa, text[i]);
                i += 1;
            }
            if (i >= text.len) return error.UnexpectedEnd;
            i += 1;
            try out.append(gpa, .{ .string = try buf.toOwnedSlice(gpa) });
            continue;
        }
        const start = i;
        while (i < text.len and text[i] != '(' and text[i] != ')' and text[i] != ' ' and text[i] != '\t' and text[i] != '\n' and text[i] != '\r') i += 1;
        const word = text[start..i];
        if (word.len == 0) return error.UnexpectedEnd;
        if (parseNumber(word)) |n| {
            try out.append(gpa, .{ .number = n });
        } else {
            try out.append(gpa, .{ .symbol = try gpa.dupe(u8, word) });
        }
    }
}

fn parseNumber(word: []const u8) ?f64 {
    var i: usize = 0;
    if (word.len > 0 and (word[0] == '-' or word[0] == '+')) i = 1;
    if (i >= word.len) return null;
    var digits: usize = 0;
    while (i < word.len) : (i += 1) {
        const c = word[i];
        if (c == '.') continue;
        if (c < '0' or c > '9') return null;
        digits += 1;
    }
    if (digits == 0) return null;
    return std.fmt.parseFloat(f64, word) catch null;
}

fn parseNode(gpa: Allocator, tokens: []Token, index: *usize) !SExp {
    if (index.* >= tokens.len) return error.UnexpectedEnd;
    const tok = tokens[index.*];
    switch (tok) {
        .symbol, .string, .number => {
            index.* += 1;
            return tokenToSExp(tok).?;
        },
        .close => return error.UnbalancedParen,
        .open => {
            index.* += 1;
            var items: std.ArrayList(SExp) = .empty;
            errdefer {
                for (items.items) |item| free(gpa, item);
                items.deinit(gpa);
            }
            while (index.* < tokens.len) {
                if (tokens[index.*] == .close) {
                    index.* += 1;
                    return .{ .list = try items.toOwnedSlice(gpa) };
                }
                const item = try parseNode(gpa, tokens, index);
                errdefer free(gpa, item);
                try items.append(gpa, item);
            }
            return error.UnbalancedParen;
        },
    }
}

fn tokenToSExp(tok: Token) ?SExp {
    return switch (tok) {
        .symbol => |s| .{ .symbol = s },
        .string => |s| .{ .string = s },
        .number => |n| .{ .number = n },
        else => null,
    };
}

fn isBlock(node: SExp, name: []const u8) bool {
    return node == .list and node.list.len > 0 and node.list[0] == .symbol and std.mem.eql(u8, node.list[0].symbol, name);
}

/// 第一个以 `name` 开头的子表。
pub fn child(node: SExp, name: []const u8) ?SExp {
    switch (node) {
        .list => |items| {
            for (items) |item| {
                if (isBlock(item, name)) return item;
            }
            return null;
        },
        else => return null,
    }
}

pub fn collect(gpa: Allocator, node: SExp, name: []const u8) ![]SExp {
    var out: std.ArrayList(SExp) = .empty;
    errdefer out.deinit(gpa);
    if (node == .list) {
        for (node.list) |item| {
            if (isBlock(item, name)) {
                try out.append(gpa, item);
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn numberAt(node: ?SExp, index: usize) ?f64 {
    const node_val = node orelse return null;
    switch (node_val) {
        .list => |items| {
            if (index >= items.len) return null;
            if (items[index] == .number) return items[index].number;
            return null;
        },
        .number => |num| return num,
        else => return null,
    }
}

fn stringAt(node: ?SExp, index: usize) []const u8 {
    const node_val = node orelse return "";
    switch (node_val) {
        .list => |items| {
            if (index >= items.len) return "";
            if (items[index] == .string) return items[index].string;
            return "";
        },
        .string => |s| return s,
        else => return "",
    }
}

fn rotate(p: geometry.Point, deg: f64) geometry.Point {
    if (deg == 0.0) return p;
    const rad = deg * std.math.pi / 180.0;
    const c = @cos(rad);
    const s = @sin(rad);
    return .{ .x = p.x * c - p.y * s, .y = p.x * s + p.y * c };
}

pub const PadInfo = struct {
    pad: []const u8,
    net: []const u8,
    pos: geometry.Point,
};

pub const FootprintInfo = struct {
    ref: []const u8,
    name: []const u8,
    origin: geometry.Point,
    rotation_deg: f64,
    pads: []PadInfo,

    pub fn free(self: *const FootprintInfo, gpa: Allocator) void {
        gpa.free(self.ref);
        gpa.free(self.name);
        for (self.pads) |p| {
            gpa.free(p.pad);
            gpa.free(p.net);
        }
        gpa.free(self.pads);
    }
};

pub fn footprints(gpa: Allocator, root: SExp) ![]FootprintInfo {
    // 传入的可以是文档根（footprint 是子表），也可以直接是单个 footprint 表本身。
    var blocks: std.ArrayList(SExp) = .empty;
    defer blocks.deinit(gpa);
    if (isBlock(root, "footprint")) {
        try blocks.append(gpa, root);
    } else {
        const found = try collect(gpa, root, "footprint");
        defer gpa.free(found);
        for (found) |f| try blocks.append(gpa, f);
    }

    var out: std.ArrayList(FootprintInfo) = .empty;
    errdefer {
        for (out.items) |f| f.free(gpa);
        out.deinit(gpa);
    }

    for (blocks.items) |block| {
        const at = child(block, "at") orelse continue;
        const ox = numberAt(at, 1) orelse 0.0;
        const oy = numberAt(at, 2) orelse 0.0;
        const rot = numberAt(at, 3) orelse 0.0;

        var pads: std.ArrayList(PadInfo) = .empty;
        errdefer pads.deinit(gpa);

        const pad_blocks = try collect(gpa, block, "pad");
        defer gpa.free(pad_blocks);
        for (pad_blocks) |pad_block| {
            const pad_at = child(pad_block, "at") orelse continue;
            const world = rotate(.{ .x = numberAt(pad_at, 1) orelse 0.0, .y = numberAt(pad_at, 2) orelse 0.0 }, rot);
            try pads.append(gpa, .{
                .pad = try gpa.dupe(u8, stringAt(pad_block, 1)),
                .net = try gpa.dupe(u8, stringAt(child(pad_block, "net"), 2)),
                .pos = .{ .x = ox + world.x, .y = oy + world.y },
            });
        }

        var ref: []const u8 = "";
        const props = try collect(gpa, block, "property");
        defer gpa.free(props);
        for (props) |prop| {
            if (std.mem.eql(u8, stringAt(prop, 1), "Reference")) {
                ref = stringAt(prop, 2);
                break;
            }
        }

        try out.append(gpa, .{
            .ref = try gpa.dupe(u8, ref),
            .name = try gpa.dupe(u8, stringAt(block, 1)),
            .origin = .{ .x = ox, .y = oy },
            .rotation_deg = rot,
            .pads = try pads.toOwnedSlice(gpa),
        });
    }

    return out.toOwnedSlice(gpa);
}

const Bounds = struct {
    min_x: ?f64 = null,
    min_y: ?f64 = null,
    max_x: ?f64 = null,
    max_y: ?f64 = null,

    fn add(self: *Bounds, x: f64, y: f64) void {
        if (self.min_x == null or x < self.min_x.?) self.min_x = x;
        if (self.min_y == null or y < self.min_y.?) self.min_y = y;
        if (self.max_x == null or x > self.max_x.?) self.max_x = x;
        if (self.max_y == null or y > self.max_y.?) self.max_y = y;
    }

    fn rect(self: *const Bounds) geometry.Rect {
        if (self.min_x == null) return .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 0, .y = 0 } };
        return .{
            .min = .{ .x = self.min_x.?, .y = self.min_y.? },
            .max = .{ .x = self.max_x.?, .y = self.max_y.? },
        };
    }
};

/// 由 Edge.Cuts 折线与圆求板框。
pub fn boardBounds(gpa: Allocator, root: SExp) !geometry.Rect {
    var bounds = Bounds{};

    const segments = try collect(gpa, root, "segment");
    defer gpa.free(segments);
    for (segments) |seg| {
        // layer 是子表：(segment (start ...) (end ...) (width ...) (layer "Edge.Cuts"))
        if (!std.mem.eql(u8, stringAt(child(seg, "layer"), 1), "Edge.Cuts")) continue;
        const start = child(seg, "start") orelse continue;
        const end = child(seg, "end") orelse continue;
        bounds.add(numberAt(start, 1) orelse 0.0, numberAt(start, 2) orelse 0.0);
        bounds.add(numberAt(end, 1) orelse 0.0, numberAt(end, 2) orelse 0.0);
    }

    const circles = try collect(gpa, root, "circle");
    defer gpa.free(circles);
    for (circles) |circle| {
        if (!std.mem.eql(u8, stringAt(child(circle, "layer"), 1), "Edge.Cuts")) continue;
        const center = child(circle, "center") orelse continue;
        const cx = numberAt(center, 1) orelse 0.0;
        const cy = numberAt(center, 2) orelse 0.0;
        const r = numberAt(circle, 3) orelse 0.0;
        bounds.add(cx - r, cy - r);
        bounds.add(cx + r, cy + r);
    }

    return bounds.rect();
}

/// 把 `.kicad_pcb` 文本读入 `pcb.Board`（调用方负责 deinit）。
pub fn readBoard(gpa: Allocator, text: []const u8) !pcb.Board {
    const root = try parse(gpa, text);
    defer free(gpa, root);

    var board = try pcb.Board.init(gpa, "kicad");
    errdefer board.deinit();

    board.bounds = try boardBounds(gpa, root);

    const infos = try footprints(gpa, root);
    defer {
        for (infos) |f| f.free(gpa);
        gpa.free(infos);
    }

    for (infos) |f| {
        var bounds = Bounds{};
        for (f.pads) |p| bounds.add(p.pos.x, p.pos.y);
        const r = bounds.rect();
        for (f.pads) |p| try board.addPad(.{ .component = f.ref, .net = p.net, .pos = p.pos });
        try board.addComponent(.{
            .ref = f.ref,
            .footprint = f.name,
            .center = f.origin,
            .rotation_deg = f.rotation_deg,
            .width = r.width(),
            .height = r.height(),
            .courtyard_margin = 0.25,
        });
    }

    const holes = try collect(gpa, root, "hole");
    defer gpa.free(holes);
    for (holes) |hole| {
        const position = child(hole, "position");
        try board.addHole(.{
            .ref = "HOLE",
            .pos = .{ .x = numberAt(position, 1) orelse 0.0, .y = numberAt(position, 2) orelse 0.0 },
            .diameter = numberAt(child(hole, "diameter"), 1) orelse 0.0,
        });
    }

    return board;
}

test "kicad s-expression parse" {
    const gpa = std.testing.allocator;
    const root = try parse(gpa, "(footprint \"QFP\" (at 10 10 90) (property \"Reference\" \"U1\" (at 0 0 0)) (pad 1 smd rect (at 0 0) (size 0.5 0.5) (layers F_Cu) (net 0 \"GND\")))");
    defer free(gpa, root);

    try std.testing.expect(child(root, "at") != null);
    const pads = try collect(gpa, root, "pad");
    defer gpa.free(pads);
    try std.testing.expectEqual(@as(usize, 1), pads.len);

    const infos = try footprints(gpa, root);
    defer {
        for (infos) |f| f.free(gpa);
        gpa.free(infos);
    }
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqualStrings("U1", infos[0].ref);
    // 90 度旋转：(0,0) 仍是原点
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), infos[0].pads[0].pos.x, 0.0001);
}

test "kicad board read" {
    const gpa = std.testing.allocator;
    const text =
        \\(kicad_pcb
        \\  (segment (start 0 0) (end 40 0) (width 0.2) (layer "Edge.Cuts"))
        \\  (segment (start 40 0) (end 40 30) (width 0.2) (layer "Edge.Cuts"))
        \\  (segment (start 40 30) (end 0 30) (width 0.2) (layer "Edge.Cuts"))
        \\  (segment (start 0 30) (end 0 0) (width 0.2) (layer "Edge.Cuts"))
        \\  (circle (center 20 15) (radius 2) (width 0.2) (layer "Edge.Cuts"))
        \\  (hole (position 5 5) (diameter 3.2))
        \\  (footprint "Package_QFP:LQFP-32_7x7mm" (at 10 10 0)
        \\    (property "Reference" "U1" (at 10 10 0))
        \\    (pad 1 smd rect (at 0 0) (size 0.5 0.5) (layers F_Cu) (net 1 "GND"))
        \\    (pad 2 smd rect (at 3 0) (size 0.5 0.5) (layers F_Cu) (net 2 "VBUS"))
        \\  )
        \\)
    ;

    var board = try readBoard(gpa, text);
    defer board.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 40.0), board.bounds.width(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), board.bounds.height(), 0.0001);
    try std.testing.expectEqual(@as(usize, 1), board.components.items.len);
    try std.testing.expectEqualStrings("U1", board.components.items[0].ref);
    try std.testing.expectEqual(@as(usize, 2), board.pads.items.len);
    try std.testing.expectEqual(@as(usize, 1), board.holes.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), board.holes.items[0].diameter, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), board.pads.items[1].pos.x - board.pads.items[0].pos.x, 0.0001);
}
