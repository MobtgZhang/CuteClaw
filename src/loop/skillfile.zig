//! SKILL.md 加载器（agentskills.io 标准）：frontmatter 只有 name 与 description，
//! 正文按需加载（progressive disclosure）——未触发的技能不占上下文。
//!
//! 必须与 DeepSeek Harness（Cordis）插件清单共存：SKILL.md 是描述层，
//! package.json 的 manifestVersion 1 仍是运行时契约，两者不能互相替代。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const Allocator = std.mem.Allocator;

pub const max_name_len: usize = 64;
pub const max_description_len: usize = 1024;

pub const SkillError = error{
    MissingFrontmatter,
    InvalidFrontmatter,
    InvalidName,
    NameTooLong,
    DescriptionTooLong,
    OutOfMemory,
};

pub const SkillFile = struct {
    gpa: Allocator,
    path: []const u8,
    name: []const u8,
    description: []const u8,
    body: []const u8,

    pub fn free(self: *const SkillFile, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.body);
    }
};

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-') continue;
        return false;
    }
    return true;
}

pub fn parse(gpa: Allocator, path: []const u8, text: []const u8) !SkillFile {
    const trimmed = std.mem.trim(u8, text, "\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return error.MissingFrontmatter;

    var lines = std.mem.splitAny(u8, trimmed, "\n");
    _ = lines.next(); // 起始的 ---

    var frontmatter: std.ArrayList([]const u8) = .empty;
    defer frontmatter.deinit(
        gpa,
    );

    var body_lines: std.ArrayList([]const u8) = .empty;
    defer body_lines.deinit(
        gpa,
    );

    var closed = false;
    while (lines.next()) |line| {
        if (!closed) {
            // frontmatter 的结束必须是独占一行的 ---：值里带连字符不算结束。
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "---")) {
                closed = true;
                continue;
            }
            try frontmatter.append(gpa, line);
            continue;
        }
        try body_lines.append(gpa, line);
    }
    if (!closed) return error.InvalidFrontmatter;

    var name: []const u8 = "";
    var description: []const u8 = "";

    for (frontmatter.items) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidFrontmatter;
        const key = std.mem.trim(u8, line[0..sep], " \t");
        const value = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) name = value;
        if (std.mem.eql(u8, key, "description")) description = value;
    }

    if (name.len == 0 or description.len == 0) return error.InvalidFrontmatter;
    if (name.len > max_name_len) return error.NameTooLong;
    if (description.len > max_description_len) return error.DescriptionTooLong;
    if (!isValidName(name)) return error.InvalidName;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(
        gpa,
    );
    for (body_lines.items, 0..) |line, i| {
        if (i > 0) try body.append(gpa, '\n');
        try body.appendSlice(gpa, line);
    }

    return .{
        .gpa = gpa,
        .path = try gpa.dupe(u8, path),
        .name = try gpa.dupe(u8, name),
        .description = try gpa.dupe(u8, description),
        .body = try gpa.dupe(u8, std.mem.trim(u8, body.items, "\r\n")),
    };
}

/// progressive disclosure：未触发只返回元数据，正文不进上下文。
pub fn loadBody(self: *const SkillFile, triggered: bool) ![]const u8 {
    if (!triggered) return "";
    return self.gpa.dupe(u8, self.body);
}

/// 触发词来自描述与技能名：描述是自然语言（停用词太短，门槛 4），
/// 技能名是标识符（`pcb`、`drc` 这类领域缩写本身就是触发词，门槛 3）。
fn keywords(gpa: Allocator, text: []const u8, min_len: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |k| gpa.free(k);
        out.deinit(
            gpa,
        );
    }
    var it = std.mem.splitAny(u8, text, " \t\n.,()[]{}:;/-_");
    while (it.next()) |w| {
        if (w.len < min_len) continue;
        try out.append(gpa, try std.ascii.allocLowerString(gpa, w));
    }
    return out.toOwnedSlice(
        gpa,
    );
}

pub fn triggerMatch(self: *const SkillFile, phrase: []const u8) !bool {
    const keys = try keywords(self.gpa, self.description, 4);
    const name_keys = try keywords(self.gpa, self.name, 3);
    defer {
        for (keys) |k| self.gpa.free(k);
        self.gpa.free(keys);
        for (name_keys) |k| self.gpa.free(k);
        self.gpa.free(name_keys);
    }

    const lower = try std.ascii.allocLowerString(self.gpa, phrase);
    defer self.gpa.free(lower);

    for (keys) |k| {
        if (std.mem.indexOf(u8, lower, k) != null) return true;
    }
    for (name_keys) |k| {
        if (std.mem.indexOf(u8, lower, k) != null) return true;
    }
    return false;
}

pub const TriggerResult = struct {
    passed: bool,
    positives_matched: usize,
    negatives_triggered: usize,
    failures: []const []const u8,

    pub fn free(self: *const TriggerResult, gpa: Allocator) void {
        for (self.failures) |f| gpa.free(f);
        gpa.free(self.failures);
    }
};

/// 触发测试：正例必须命中，负例必须不命中。负例命中说明描述太宽，技能会误触发。
pub fn triggerTest(self: *const SkillFile, positives: []const []const u8, negatives: []const []const u8) !TriggerResult {
    const gpa = self.gpa;
    var failures: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (failures.items) |f| gpa.free(f);
        failures.deinit(
            gpa,
        );
    }

    var positives_matched: usize = 0;
    for (positives) |p| {
        if (try triggerMatch(self, p)) {
            positives_matched += 1;
        } else {
            try failures.append(gpa, try gpa.dupe(u8, p));
        }
    }

    var negatives_triggered: usize = 0;
    for (negatives) |n| {
        if (try triggerMatch(self, n)) {
            negatives_triggered += 1;
            try failures.append(gpa, try gpa.dupe(u8, n));
        }
    }

    return .{
        .passed = failures.items.len == 0,
        .positives_matched = positives_matched,
        .negatives_triggered = negatives_triggered,
        .failures = try failures.toOwnedSlice(
            gpa,
        ),
    };
}

/// DSH 共存检查：manifestVersion 必须仍然是 1，SKILL.md 不能替代它。
pub fn dshManifestCompatible(manifest: std.json.Value) bool {
    if (manifest != .object) return false;
    const dsh = manifest.object.get("dsh");
    if (dsh == null or dsh.? != .object) return false;
    const version = dsh.?.object.get("manifestVersion");
    if (version == null or version.? != .integer) return false;
    return version.?.integer == 1;
}

test "frontmatter parses name and description" {
    const gpa = std.testing.allocator;
    const text = "---\nname: pcb-design-review\ndescription: Review PCB layouts for DRC and manufacturability\n---\nRun the DRC gate before any conclusion.\n";
    const skill = try parse(gpa, "skills/pcb-design-review/SKILL.md", text);
    defer skill.free(gpa);

    try std.testing.expectEqualStrings("pcb-design-review", skill.name);
    try std.testing.expectEqualStrings("Review PCB layouts for DRC and manufacturability", skill.description);
    try std.testing.expectEqualStrings("Run the DRC gate before any conclusion.", skill.body);
    try std.testing.expect(isValidName("tolerance-stackup"));
    try std.testing.expect(!isValidName("Tolerance_Stackup"));
}

test "frontmatter is required and bounded" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingFrontmatter, parse(gpa, "x", "no frontmatter here"));
    try std.testing.expectError(error.InvalidFrontmatter, parse(gpa, "x", "---\nname: only-name\n---\nbody\n"));

    const long_name = comptime repeat(65, "a");
    const text = try std.fmt.allocPrint(gpa, "---\nname: {s}\ndescription: ok\n---\n", .{long_name});
    defer gpa.free(text);
    try std.testing.expectError(error.NameTooLong, parse(gpa, "x", text));
}

test "progressive disclosure keeps untriggered skills out of context" {
    const gpa = std.testing.allocator;
    const text = "---\nname: dieline-export\ndescription: Export dielines with cut crease perforation layers\n---\n" ++ comptime repeat(1200, "x");
    const skill = try parse(gpa, "skills/dieline-export/SKILL.md", text);
    defer skill.free(gpa);

    const cold = try loadBody(&skill, false);
    try std.testing.expectEqual(@as(usize, 0), cold.len);

    const hot = try loadBody(&skill, true);
    defer gpa.free(hot);
    try std.testing.expect(hot.len > 1000);
}

fn repeat(comptime n: usize, comptime s: []const u8) [n * s.len]u8 {
    @setEvalBranchQuota(100000);
    var out: [n * s.len]u8 = undefined;
    for (0..n) |i| {
        for (s, 0..) |c, j| out[i * s.len + j] = c;
    }
    return out;
}

test "trigger test rejects descriptions that over-match" {
    const gpa = std.testing.allocator;
    const text = "---\nname: pcb-design-review\ndescription: Review PCB layouts for DRC violations and manufacturability\n---\nbody\n";
    const skill = try parse(gpa, "skills/pcb-design-review/SKILL.md", text);
    defer skill.free(gpa);

    const ok = try triggerTest(&skill, &.{"run a DRC review on this PCB layout"}, &.{"write a haiku about the sea"});
    defer ok.free(gpa);
    try std.testing.expect(ok.passed);
    try std.testing.expectEqual(@as(usize, 1), ok.positives_matched);
    try std.testing.expectEqual(@as(usize, 0), ok.negatives_triggered);

    const bad = try triggerTest(&skill, &.{"something unrelated entirely"}, &.{"check the DRC violations"});
    defer bad.free(gpa);
    try std.testing.expect(!bad.passed);
    try std.testing.expectEqual(@as(usize, 2), bad.failures.len);
    try std.testing.expectEqual(@as(usize, 1), bad.negatives_triggered);
}

test "SKILL.md coexists with the DSH manifest contract" {
    const gpa = std.testing.allocator;
    const manifest = try ju.parseValue(gpa, "{\"name\":\"pcb-design-review\",\"dsh\":{\"manifestVersion\":1,\"bundle\":\"index.js\"}}");
    defer ju.freeJsonValue(gpa, manifest);
    try std.testing.expect(dshManifestCompatible(manifest));

    const wrong = try ju.parseValue(gpa, "{\"dsh\":{\"manifestVersion\":2}}");
    defer ju.freeJsonValue(gpa, wrong);
    try std.testing.expect(!dshManifestCompatible(wrong));

    const missing = try ju.parseValue(gpa, "{\"name\":\"x\"}");
    defer ju.freeJsonValue(gpa, missing);
    try std.testing.expect(!dshManifestCompatible(missing));
}
