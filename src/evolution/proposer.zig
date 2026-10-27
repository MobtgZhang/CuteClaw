//! 提议阶段：从任务证据生成候选改动（Harness² 的 8 个可编辑组件）。
//! 自进化可以改写策略、技能与工具指引，但不得自动修改安全护栏与硬设计规范。

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Component = enum {
    system_prompt,
    guardrails,
    memory,
    tool_guidance,
    subagents,
    skills,
    scripts,
    plugins,
};

pub fn componentFromString(s: []const u8) ?Component {
    if (std.mem.eql(u8, s, "system_prompt")) return .system_prompt;
    if (std.mem.eql(u8, s, "guardrails")) return .guardrails;
    if (std.mem.eql(u8, s, "memory")) return .memory;
    if (std.mem.eql(u8, s, "tool_guidance")) return .tool_guidance;
    if (std.mem.eql(u8, s, "subagents")) return .subagents;
    if (std.mem.eql(u8, s, "skills")) return .skills;
    if (std.mem.eql(u8, s, "scripts")) return .scripts;
    if (std.mem.eql(u8, s, "plugins")) return .plugins;
    return null;
}

pub fn editable(component: Component) bool {
    return component != .guardrails;
}

pub const Evidence = struct {
    task_id: []const u8,
    summary: []const u8,
    outcome: []const u8,
    lessons: []const []const u8,
};

pub const Candidate = struct {
    id: []const u8,
    component: Component,
    summary: []const u8,
    body: []const u8,
    rationale: []const u8,

    pub fn free(self: *const Candidate, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.summary);
        gpa.free(self.body);
        gpa.free(self.rationale);
    }
};

/// 按证据中的经验条目生成候选；不可编辑组件直接跳过。
pub fn propose(gpa: Allocator, evidence: []const Evidence, limit: usize) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (out.items) |c| c.free(gpa);
        out.deinit(
            gpa,
        );
    }

    for (evidence) |ev| {
        for (ev.lessons) |lesson| {
            if (out.items.len >= limit) return out.toOwnedSlice(
                gpa,
            );
            const component = pickComponent(lesson);
            if (!editable(component)) continue;
            try out.append(gpa, .{
                .id = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ ev.task_id, @tagName(component) }),
                .component = component,
                .summary = try gpa.dupe(u8, lesson),
                .body = try std.fmt.allocPrint(gpa, "apply lesson from {s}: {s}", .{ ev.task_id, lesson }),
                .rationale = try std.fmt.allocPrint(gpa, "evidence outcome={s}", .{ev.outcome}),
            });
        }
    }

    return out.toOwnedSlice(
        gpa,
    );
}

fn pickComponent(lesson: []const u8) Component {
    if (std.mem.indexOf(u8, lesson, "tool") != null) return .tool_guidance;
    if (std.mem.indexOf(u8, lesson, "memory") != null) return .memory;
    if (std.mem.indexOf(u8, lesson, "skill") != null) return .skills;
    if (std.mem.indexOf(u8, lesson, "plugin") != null) return .plugins;
    if (std.mem.indexOf(u8, lesson, "script") != null) return .scripts;
    if (std.mem.indexOf(u8, lesson, "guardrail") != null) return .guardrails;
    return .system_prompt;
}

test "propose from evidence" {
    const gpa = std.testing.allocator;
    const lessons = [_][]const u8{ "cluster tools before routing", "memory: keep connector first", "guardrail must not be auto-edited" };
    const evidence = [_]Evidence{.{
        .task_id = "t1",
        .summary = "pcb layout",
        .outcome = "success",
        .lessons = &lessons,
    }};

    const candidates = try propose(gpa, &evidence, 10);
    defer {
        for (candidates) |c| c.free(gpa);
        gpa.free(candidates);
    }

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqual(Component.tool_guidance, candidates[0].component);
    try std.testing.expectEqual(Component.memory, candidates[1].component);
    try std.testing.expect(!editable(Component.guardrails));
    try std.testing.expectEqual(@as(?Component, Component.skills), componentFromString("skills"));
}

test "propose respects limit" {
    const gpa = std.testing.allocator;
    const lessons = [_][]const u8{ "a lesson", "b lesson", "c lesson" };
    const evidence = [_]Evidence{.{ .task_id = "t", .summary = "s", .outcome = "success", .lessons = &lessons }};
    const candidates = try propose(gpa, &evidence, 2);
    defer {
        for (candidates) |c| c.free(gpa);
        gpa.free(candidates);
    }
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
}
