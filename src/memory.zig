//! 三类记忆：情景（轨迹）、语义（事实）、程序（技能 / SOP）。

const std = @import("std");

/// 单次任务结束时的粗粒度标签，供进化流水线与指标使用。
pub const TaskOutcome = enum {
    success,
    failed,
    aborted,
    needs_human,
};

pub fn outcomeTag(o: TaskOutcome) []const u8 {
    return switch (o) {
        .success => "success",
        .failed => "failed",
        .aborted => "aborted",
        .needs_human => "needs_human",
    };
}

/// 解析持久化 / JSON 中的 outcome 字符串，未知则返回 null。
pub fn outcomeFromString(s: []const u8) ?TaskOutcome {
    if (std.mem.eql(u8, s, "success")) return .success;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "aborted")) return .aborted;
    if (std.mem.eql(u8, s, "needs_human")) return .needs_human;
    return null;
}

/// 情景记忆：append-only 事件摘要，带任务标识与时间戳。
pub const EpisodicRecord = struct {
    task_id: []const u8,
    ended_unix: i64,
    summary: []const u8,
    outcome: TaskOutcome,
};

/// 语义记忆：结构化事实（键值 + 置信度）。
pub const SemanticFact = struct {
    key: []const u8,
    value: []const u8,
    /// 0.0 ~ 1.0，由上层策略写入；本模块不做归一化校验。
    confidence: f32,
};

/// 程序记忆：带版本与前置条件的技能片段（可对应 SOP 或工具规程）。
pub const SkillVersion = struct {
    name: []const u8,
    version: []const u8,
    preconditions: []const u8,
    prohibitions: []const u8,
    body: []const u8,
};

test "task outcome tag size" {
    try std.testing.expect(@intFromEnum(TaskOutcome.success) >= 0);
}

test "outcome roundtrip strings" {
    const all = [_]TaskOutcome{ .success, .failed, .aborted, .needs_human };
    for (all) |o| {
        const t = outcomeTag(o);
        try std.testing.expectEqual(o, outcomeFromString(t).?);
    }
    try std.testing.expect(outcomeFromString("nope") == null);
}
