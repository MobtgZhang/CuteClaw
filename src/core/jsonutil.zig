//! JSON 动态值工具：所有权统一为「由 gpa 分配、调用方用 freeJsonValue 释放」。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn copyJsonValue(gpa: Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float, .number_string => v,
        .string => .{ .string = try gpa.dupe(u8, v.string) },
        .array => blk: {
            var arr = std.json.Array.init(gpa);
            errdefer arr.deinit();
            for (v.array.items) |item| try arr.append(try copyJsonValue(gpa, item));
            break :blk .{ .array = arr };
        },
        .object => blk: {
            var obj = std.json.ObjectMap.empty;
            errdefer obj.deinit(
                gpa,
            );
            var it = v.object.iterator();
            while (it.next()) |e| try obj.put(gpa, try gpa.dupe(u8, e.key_ptr.*), try copyJsonValue(gpa, e.value_ptr.*));
            break :blk .{ .object = obj };
        },
    };
}

pub fn freeJsonValue(gpa: Allocator, v: std.json.Value) void {
    switch (v) {
        .string => |s| gpa.free(s),
        .array => |arr| {
            var a = arr;
            for (a.items) |item| freeJsonValue(gpa, item);
            a.deinit();
        },
        .object => |obj| {
            var m = obj;
            var it = m.iterator();
            while (it.next()) |e| {
                gpa.free(e.key_ptr.*);
                freeJsonValue(gpa, e.value_ptr.*);
            }
            m.deinit(
                gpa,
            );
        },
        else => {},
    }
}

pub fn objGet(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

pub fn objStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = objGet(obj, key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

pub fn objNum(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = objGet(obj, key) orelse return 0;
    switch (v) {
        .integer => |i| return if (i > 0) @intCast(i) else 0,
        .float => |f| return if (f > 0) @intFromFloat(f) else 0,
        else => return 0,
    }
}

pub fn putKey(gpa: Allocator, map: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try map.put(gpa, try gpa.dupe(u8, key), value);
}

pub fn strVal(gpa: Allocator, s: []const u8) !std.json.Value {
    return .{ .string = try gpa.dupe(u8, s) };
}

pub fn newArr(gpa: Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(gpa) };
}

pub fn newObj(gpa: Allocator) std.json.Value {
    _ = gpa;
    return .{ .object = std.json.ObjectMap.empty };
}

pub fn stringifyAlloc(gpa: Allocator, v: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try std.json.Stringify.value(v, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

pub fn parseValue(gpa: Allocator, text: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    return copyJsonValue(gpa, parsed.value);
}

test "json value copy is independent" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"a\":\"x\",\"b\":[1,2]}", .{});
    defer parsed.deinit();
    const copy = try copyJsonValue(gpa, parsed.value);
    defer freeJsonValue(gpa, copy);
    try std.testing.expectEqualStrings("x", objStr(copy.object, "a"));
    try std.testing.expectEqual(@as(usize, 2), copy.object.get("b").?.array.items.len);
}

test "stringify alloc roundtrip" {
    const gpa = std.testing.allocator;
    var v = newObj(gpa);
    try putKey(gpa, &v.object, "k", try strVal(gpa, "v"));
    const text = try stringifyAlloc(gpa, v);
    defer gpa.free(text);
    defer freeJsonValue(gpa, v);
    try std.testing.expectEqualStrings("{\"k\":\"v\"}", text);
}
