//! 显式工作区：短生命周期、固定语义字段，避免与长对话链混写。

const std = @import("std");

/// 当前任务的可变工作集；切片由调用方拥有（或由 Arena 托管）。
pub const WorkingSet = struct {
    goal: []const u8 = "",
    constraints: []const u8 = "",
    confirmed_facts: []const u8 = "",
    next_step: []const u8 = "",

    pub fn isEmpty(self: WorkingSet) bool {
        return self.goal.len == 0 and self.constraints.len == 0 and
            self.confirmed_facts.len == 0 and self.next_step.len == 0;
    }

    /// 将工作集格式化为人类可读块，便于注入提示词或日志。
    pub fn formatBlock(self: WorkingSet, writer: anytype) !void {
        try writer.writeAll("### CuteClaw WorkingSet\n");
        try writer.print("goal: {s}\n", .{self.goal});
        try writer.print("constraints: {s}\n", .{self.constraints});
        try writer.print("confirmed_facts: {s}\n", .{self.confirmed_facts});
        try writer.print("next_step: {s}\n", .{self.next_step});
    }
};

test "working set empty" {
    const w: WorkingSet = .{};
    try std.testing.expect(w.isEmpty());
}
