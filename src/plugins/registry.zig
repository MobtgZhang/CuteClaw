//! 可撤销注册（Cordis 的 ctx.effect() 语义）：注册顺序记录、回滚时逆序执行 undo。

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const EffectFn = *const fn (ctx: *anyopaque, gpa: Allocator) anyerror!void;

pub const Effect = struct {
    plugin_id: []const u8,
    kind: []const u8,
    ctx: *anyopaque = undefined,
    apply: EffectFn,
    undo: EffectFn,
};

pub const EffectRegistry = struct {
    gpa: Allocator,
    effects: std.ArrayList(Effect),

    pub fn init(gpa: Allocator) EffectRegistry {
        return .{ .gpa = gpa, .effects = .empty };
    }

    pub fn deinit(self: *EffectRegistry) void {
        self.effects.deinit(self.gpa);
    }

    pub fn add(self: *EffectRegistry, effect: Effect) !void {
        try self.effects.append(self.gpa, effect);
        try effect.apply(effect.ctx, self.gpa);
    }

    pub fn count(self: *EffectRegistry, plugin_id: []const u8) usize {
        var n: usize = 0;
        for (self.effects.items) |e| {
            if (std.mem.eql(u8, e.plugin_id, plugin_id)) n += 1;
        }
        return n;
    }

    /// 逆序回滚指定插件的全部效果，返回回滚数量。
    pub fn rollback(self: *EffectRegistry, plugin_id: []const u8) !usize {
        var done: usize = 0;
        var i: usize = self.effects.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.effects.items[i];
            if (!std.mem.eql(u8, e.plugin_id, plugin_id)) continue;
            try e.undo(e.ctx, self.gpa);
            done += 1;
        }
        return done;
    }
};

const TestState = struct { applied: usize = 0, undone: usize = 0 };

fn applyEffect(ctx: *anyopaque, gpa: Allocator) anyerror!void {
    _ = gpa;
    const st = @as(*TestState, @ptrCast(@alignCast(ctx)));
    st.applied += 1;
}

fn undoEffect(ctx: *anyopaque, gpa: Allocator) anyerror!void {
    _ = gpa;
    const st = @as(*TestState, @ptrCast(@alignCast(ctx)));
    st.undone += 1;
}

test "reversible effects" {
    const gpa = std.testing.allocator;
    var reg = EffectRegistry.init(gpa);
    defer reg.deinit();

    var state = TestState{};
    try reg.add(.{ .plugin_id = "p1", .kind = "tool", .ctx = &state, .apply = applyEffect, .undo = undoEffect });
    try reg.add(.{ .plugin_id = "p2", .kind = "hook", .ctx = &state, .apply = applyEffect, .undo = undoEffect });
    try std.testing.expectEqual(@as(usize, 1), reg.count("p1"));
    try std.testing.expectEqual(@as(usize, 2), state.applied);

    const rolled = try reg.rollback("p1");
    try std.testing.expectEqual(@as(usize, 1), rolled);
    try std.testing.expectEqual(@as(usize, 1), state.undone);
}
