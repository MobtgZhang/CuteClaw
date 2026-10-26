//! 二维几何：点、矩形、多边形与距离（PCB 与外壳配合检查共用）。

const std = @import("std");

pub const Point = struct {
    x: f64,
    y: f64,

    pub fn distanceTo(self: Point, other: Point) f64 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

pub const Rect = struct {
    min: Point,
    max: Point,

    pub fn width(self: Rect) f64 {
        return self.max.x - self.min.x;
    }

    pub fn height(self: Rect) f64 {
        return self.max.y - self.min.y;
    }

    pub fn area(self: Rect) f64 {
        return self.width() * self.height();
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.min.x and p.x <= self.max.x and p.y >= self.min.y and p.y <= self.max.y;
    }

    pub fn containsRect(self: Rect, other: Rect) bool {
        return self.contains(other.min) and self.contains(other.max);
    }

    pub fn expand(self: Rect, margin: f64) Rect {
        return .{
            .min = .{ .x = self.min.x - margin, .y = self.min.y - margin },
            .max = .{ .x = self.max.x + margin, .y = self.max.y + margin },
        };
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.gap(other) <= 0.0000001;
    }

    /// 两个矩形之间的最小欧氏间隙（重叠时为 0）。
    pub fn gap(self: Rect, other: Rect) f64 {
        const dx = @max(0.0, @max(self.min.x - other.max.x, other.min.x - self.max.x));
        const dy = @max(0.0, @max(self.min.y - other.max.y, other.min.y - self.max.y));
        return @sqrt(dx * dx + dy * dy);
    }
};

pub fn rectFromCenter(center: Point, w: f64, h: f64, rotation_deg: f64) Rect {
    var half_w = w / 2.0;
    var half_h = h / 2.0;
    if (rotation_deg != 0.0) {
        const rad = rotation_deg * std.math.pi / 180.0;
        const c = @abs(@cos(rad));
        const s = @abs(@sin(rad));
        half_w = (w * c + h * s) / 2.0;
        half_h = (w * s + h * c) / 2.0;
    }
    return .{
        .min = .{ .x = center.x - half_w, .y = center.y - half_h },
        .max = .{ .x = center.x + half_w, .y = center.y + half_h },
    };
}

pub fn polygonArea(points: []const Point) f64 {
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < points.len) {
        const a = points[i];
        const b = points[(i + 1) % points.len];
        sum += a.x * b.y - b.x * a.y;
        i += 1;
    }
    return @abs(sum) / 2.0;
}

pub fn pointInPolygon(p: Point, points: []const Point) bool {
    if (points.len < 3) return false;
    var inside = false;
    var i: usize = 0;
    var j: usize = points.len - 1;
    while (i < points.len) {
        const a = points[i];
        const b = points[j];
        const intersect = (a.y > p.y) != (b.y > p.y) and
            p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
        if (intersect) inside = !inside;
        j = i;
        i += 1;
    }
    return inside;
}

test "rect gap and containment" {
    const a = Rect{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 10, .y = 10 } };
    const b = Rect{ .min = .{ .x = 12, .y = 0 }, .max = .{ .x = 14, .y = 4 } };
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), a.gap(b), 0.0001);
    try std.testing.expect(a.contains(.{ .x = 5, .y = 5 }));
    try std.testing.expect(!a.contains(.{ .x = 11, .y = 5 }));
    try std.testing.expect(!a.containsRect(b));
    try std.testing.expect(a.containsRect(a.expand(-2.0)));
    try std.testing.expect(!a.overlaps(b));
}

test "polygon area and rotation" {
    const square = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 4, .y = 4 },
        .{ .x = 0, .y = 4 },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 16.0), polygonArea(&square), 0.0001);
    try std.testing.expect(pointInPolygon(.{ .x = 2, .y = 2 }, &square));
    try std.testing.expect(!pointInPolygon(.{ .x = 6, .y = 2 }, &square));

    const r = rectFromCenter(.{ .x = 0, .y = 0 }, 10, 2, 90);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), r.width(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), r.height(), 0.0001);
}
