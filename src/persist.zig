//! JSON 快照持久化（schema v1）：原子写入、与 `ClawRuntime` 双向同步。

const std = @import("std");
const memory = @import("memory.zig");
const working = @import("working.zig");
const metrics = @import("metrics.zig");
const claw = @import("claw.zig");
const ver = @import("version.zig");

const Allocator = std.mem.Allocator;

pub const schema_version_v1: u32 = 1;
pub const max_file_bytes: usize = 32 * 1024 * 1024;

pub const EpisodicJson = struct {
    task_id: []const u8,
    ended_unix: i64,
    summary: []const u8,
    outcome: []const u8,
};

pub const SkillJson = struct {
    name: []const u8,
    version: []const u8,
    preconditions: []const u8 = "",
    prohibitions: []const u8 = "",
    body: []const u8,
};

pub const FactJson = struct {
    key: []const u8,
    value: []const u8,
    confidence: f32,
};

pub const RollupJson = struct {
    skill_name: []const u8,
    invocations: u32,
    successes: u32,
    failures: u32,
    last_patch_unix: i64,
};

pub const AuditJson = struct {
    unix_ts: i64,
    skill_name: []const u8,
    policy: []const u8,
    result: []const u8,
    detail: []const u8,
};

pub const WorkingJson = struct {
    goal: []const u8 = "",
    constraints: []const u8 = "",
    confirmed_facts: []const u8 = "",
    next_step: []const u8 = "",
};

pub const StoreDocumentV1 = struct {
    schema_version: u32 = schema_version_v1,
    library_version: []const u8 = "",
    saved_unix: i64 = 0,
    episodic: []const EpisodicJson = &.{},
    skills: []const SkillJson = &.{},
    facts: []const FactJson = &.{},
    rollups: []const RollupJson = &.{},
    audit: []const AuditJson = &.{},
    tasks_recorded: u64 = 0,
    tasks_succeeded: u64 = 0,
    working: WorkingJson = .{},
};

fn freeDocumentSlices(gpa: Allocator, doc: StoreDocumentV1) void {
    gpa.free(doc.episodic);
    gpa.free(doc.skills);
    gpa.free(doc.facts);
    gpa.free(doc.rollups);
    gpa.free(doc.audit);
}

/// 将当前运行时导出为 JSON（调用方 `defer allocator.free(bytes)`）。
pub fn snapshotToJsonAlloc(rt: *const claw.ClawRuntime, gpa: Allocator, saved_unix: i64) ![]u8 {
    var roll = std.ArrayList(metrics.SkillRollup).empty;
    defer roll.deinit(gpa);
    try rt.metrics.rollupSnapshot(gpa, &roll);

    var episodic_json: std.ArrayList(EpisodicJson) = .empty;
    defer episodic_json.deinit(gpa);
    for (rt.episodic.items) |e| {
        try episodic_json.append(gpa, .{
            .task_id = e.task_id,
            .ended_unix = e.ended_unix,
            .summary = e.summary,
            .outcome = memory.outcomeTag(e.outcome),
        });
    }

    var skills_json: std.ArrayList(SkillJson) = .empty;
    defer skills_json.deinit(gpa);
    for (rt.skills.items) |s| {
        try skills_json.append(gpa, .{
            .name = s.name,
            .version = s.version,
            .preconditions = s.preconditions,
            .prohibitions = s.prohibitions,
            .body = s.body,
        });
    }

    var facts_json: std.ArrayList(FactJson) = .empty;
    defer facts_json.deinit(gpa);
    for (rt.facts.items) |f| {
        try facts_json.append(gpa, .{
            .key = f.key,
            .value = f.value,
            .confidence = f.confidence,
        });
    }

    var roll_json: std.ArrayList(RollupJson) = .empty;
    defer roll_json.deinit(gpa);
    for (roll.items) |r| {
        try roll_json.append(gpa, .{
            .skill_name = r.skill_name,
            .invocations = r.invocations,
            .successes = r.successes,
            .failures = r.failures,
            .last_patch_unix = r.last_patch_unix,
        });
    }

    var audit_json: std.ArrayList(AuditJson) = .empty;
    defer audit_json.deinit(gpa);
    for (rt.metrics.audit.items) |a| {
        try audit_json.append(gpa, .{
            .unix_ts = a.unix_ts,
            .skill_name = a.skill_name,
            .policy = a.policy,
            .result = a.result,
            .detail = a.detail,
        });
    }

    const doc: StoreDocumentV1 = .{
        .schema_version = schema_version_v1,
        .library_version = ver.semantic,
        .saved_unix = saved_unix,
        .episodic = try episodic_json.toOwnedSlice(gpa),
        .skills = try skills_json.toOwnedSlice(gpa),
        .facts = try facts_json.toOwnedSlice(gpa),
        .rollups = try roll_json.toOwnedSlice(gpa),
        .audit = try audit_json.toOwnedSlice(gpa),
        .tasks_recorded = rt.metrics.tasks_recorded,
        .tasks_succeeded = rt.metrics.tasks_succeeded,
        .working = .{
            .goal = rt.working.goal,
            .constraints = rt.working.constraints,
            .confirmed_facts = rt.working.confirmed_facts,
            .next_step = rt.working.next_step,
        },
    };
    errdefer freeDocumentSlices(gpa, doc);

    const json_bytes = try std.json.Stringify.valueAlloc(gpa, doc, .{ .whitespace = .indent_2 });
    freeDocumentSlices(gpa, doc);
    return json_bytes;
}

/// 在已打开的目录内原子写入 `name`（临时文件 `name.tmp` 再 rename）。
pub fn saveToFile(rt: *const claw.ClawRuntime, dir: std.fs.Dir, gpa: Allocator, name: []const u8, saved_unix: i64) !void {
    const json_bytes = try snapshotToJsonAlloc(rt, gpa, saved_unix);
    defer gpa.free(json_bytes);

    const tmp_name = try std.fmt.allocPrint(gpa, "{s}.tmp", .{name});
    defer gpa.free(tmp_name);

    try dir.writeFile(.{ .sub_path = tmp_name, .data = json_bytes });
    try dir.rename(tmp_name, name);
}

/// 自 `cwd()` 下相对路径写入（自动 `makePath` 父目录）。
pub fn saveToPath(rt: *const claw.ClawRuntime, gpa: Allocator, path: []const u8, saved_unix: i64) !void {
    const dirname = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    try std.fs.cwd().makePath(dirname);
    var d = try std.fs.cwd().openDir(dirname, .{});
    defer d.close();
    try saveToFile(rt, d, gpa, base, saved_unix);
}

/// 从已打开目录读取 `name` 并填充 `rt`。
pub fn loadFromFile(rt: *claw.ClawRuntime, dir: std.fs.Dir, parse_gpa: Allocator, name: []const u8) !void {
    var file = try dir.openFile(name, .{});
    defer file.close();
    const data = try file.readToEndAlloc(parse_gpa, max_file_bytes);
    defer parse_gpa.free(data);

    var parsed = try std.json.parseFromSlice(StoreDocumentV1, parse_gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.schema_version != schema_version_v1)
        return error.UnsupportedSchema;

    try applyLoadedDocument(rt, parsed.value);
}

/// 自 `cwd()` 相对路径读取。
pub fn loadFromPath(rt: *claw.ClawRuntime, parse_gpa: Allocator, path: []const u8) !void {
    const dirname = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var d = try std.fs.cwd().openDir(dirname, .{});
    defer d.close();
    try loadFromFile(rt, d, parse_gpa, base);
}

/// 将已解析文档灌入运行时（供测试或宿主自管 JSON 解析时复用）。
pub fn applyLoadedDocument(rt: *claw.ClawRuntime, doc: StoreDocumentV1) !void {
    rt.resetContent();

    rt.metrics.tasks_recorded = doc.tasks_recorded;
    rt.metrics.tasks_succeeded = doc.tasks_succeeded;
    if (doc.audit.len > rt.metrics.audit_cap)
        rt.metrics.audit_cap = doc.audit.len;

    for (doc.episodic) |e| {
        const oc = memory.outcomeFromString(e.outcome) orelse return error.BadOutcome;
        try rt.rememberEpisode(.{
            .task_id = e.task_id,
            .ended_unix = e.ended_unix,
            .summary = e.summary,
            .outcome = oc,
        });
    }

    for (doc.skills) |s| {
        try rt.addSkillCopy(.{
            .name = s.name,
            .version = s.version,
            .preconditions = s.preconditions,
            .prohibitions = s.prohibitions,
            .body = s.body,
        });
    }

    for (doc.facts) |f| {
        try rt.addFact(.{
            .key = f.key,
            .value = f.value,
            .confidence = f.confidence,
        });
    }

    for (doc.rollups) |r| {
        try rt.metrics.seedRollup(.{
            .skill_name = r.skill_name,
            .invocations = r.invocations,
            .successes = r.successes,
            .failures = r.failures,
            .last_patch_unix = r.last_patch_unix,
        });
    }

    for (doc.audit) |a| {
        try rt.metrics.recordEvolution(a.unix_ts, a.skill_name, a.policy, a.result, a.detail);
    }

    try rt.setWorking(.{
        .goal = doc.working.goal,
        .constraints = doc.working.constraints,
        .confirmed_facts = doc.working.confirmed_facts,
        .next_step = doc.working.next_step,
    });
}

test "golden minimal_store_v1 embed" {
    const gpa = std.testing.allocator;
    const raw = @embedFile("../testdata/minimal_store_v1.json");
    var parsed = try std.json.parseFromSlice(StoreDocumentV1, gpa, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(schema_version_v1, parsed.value.schema_version);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.episodic.len);

    var rt = claw.ClawRuntime.init(gpa);
    defer rt.deinit();
    try applyLoadedDocument(&rt, parsed.value);
    try std.testing.expectEqual(@as(usize, 0), rt.episodic.items.len);
    try std.testing.expect(rt.working.isEmpty());
}

test "save load roundtrip" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rt = claw.ClawRuntime.init(gpa);
    defer rt.deinit();

    try rt.rememberEpisode(.{
        .task_id = "a",
        .ended_unix = 1,
        .summary = "s",
        .outcome = .success,
    });
    try rt.addFact(.{ .key = "k", .value = "v", .confidence = 0.9 });
    try rt.addSkillCopy(.{
        .name = "n",
        .version = "1.0.0",
        .preconditions = "",
        .prohibitions = "",
        .body = "body content here",
    });
    try rt.setWorking(.{ .goal = "g", .next_step = "n" });

    try saveToFile(&rt, tmp.dir, gpa, "store.json", 42);

    var rt2 = claw.ClawRuntime.init(gpa);
    defer rt2.deinit();
    try loadFromFile(&rt2, tmp.dir, gpa, "store.json");

    try std.testing.expectEqual(@as(usize, 1), rt2.episodic.items.len);
    try std.testing.expectEqualStrings("a", rt2.episodic.items[0].task_id);
    try std.testing.expectEqual(@as(usize, 1), rt2.skills.items.len);
    try std.testing.expectEqualStrings("n", rt2.skills.items[0].name);
    try std.testing.expectEqualStrings("g", rt2.working.goal);
}
