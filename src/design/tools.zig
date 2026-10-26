//! 设计引擎工具层：把工程、PCB、DRC 与外壳配合检查接入统一工具注册表。
//! 工具通过 `ToolCtx.workspace` 访问 `Workspace`，并受沙箱能力约束；插件与 Agent 共用同一入口。

const std = @import("std");
const ju = @import("../core/jsonutil.zig");
const tools = @import("../core/tools.zig");
const sandbox = @import("../sandbox/policy.zig");
const claw = @import("../claw.zig");
const geometry = @import("geometry.zig");
const pcb = @import("pcb.zig");
const project = @import("project.zig");
const constraints = @import("constraints.zig");
const validation = @import("validation.zig");
const kicad = @import("../adapters/kicad.zig");

const Allocator = std.mem.Allocator;

pub const max_read_bytes: usize = 1024 * 1024;

pub const WorkspaceError = error{
    ProjectNotFound,
    MissingArgument,
    UnknownKind,
    FileTooLarge,
};

pub const SkillEntry = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,

    pub fn free(self: *const SkillEntry, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.version);
        gpa.free(self.summary);
    }
};

pub const Workspace = struct {
    gpa: Allocator,
    policy: *sandbox.Policy,
    runtime: ?*claw.ClawRuntime = null,
    projects: std.StringHashMap(project.DesignProject),
    skills: std.ArrayList(SkillEntry),

    pub fn init(gpa: Allocator, policy: *sandbox.Policy) Workspace {
        return .{
            .gpa = gpa,
            .policy = policy,
            .projects = std.StringHashMap(project.DesignProject).init(gpa),
            .skills = .empty,
        };
    }

    pub fn deinit(self: *Workspace) void {
        var it = self.projects.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.projects.deinit();
        for (self.skills.items) |s| s.free(self.gpa);
        self.skills.deinit(self.gpa);
    }

    pub fn open(self: *Workspace, id: []const u8, name: []const u8) !*project.DesignProject {
        const entry = try self.projects.getOrPut(id);
        if (!entry.found_existing) {
            const key = try self.gpa.dupe(u8, id);
            entry.key_ptr.* = key;
            entry.value_ptr.* = try project.DesignProject.init(self.gpa, key, name);
        }
        return entry.value_ptr;
    }

    pub fn get(self: *Workspace, id: []const u8) ?*project.DesignProject {
        return self.projects.getPtr(id);
    }

    pub fn projectCount(self: *const Workspace) usize {
        return self.projects.count();
    }

    pub fn addSkill(self: *Workspace, name: []const u8, version: []const u8, summary: []const u8) !void {
        try self.skills.append(self.gpa, .{
            .name = try self.gpa.dupe(u8, name),
            .version = try self.gpa.dupe(u8, version),
            .summary = try self.gpa.dupe(u8, summary),
        });
    }

    pub fn registerTools(self: *Workspace, registry: *tools.Registry) !void {
        try registerTool(self, registry, "project_open", "打开或创建设计工程（返回工程概要）", project_open_schema, projectOpenTool);
        try registerTool(self, registry, "project_set_constraint", "为工程增加或更新一条设计约束", set_constraint_schema, setConstraintTool);
        try registerTool(self, registry, "pcb_read", "读取 KiCad .kicad_pcb（path 或 text）并写入工程的板框、器件与焊盘", pcb_read_schema, pcbReadTool);
        try registerTool(self, registry, "drc_check", "按工程约束执行 DRC，返回违规明细与是否通过", drc_check_schema, drcCheckTool);
        try registerTool(self, registry, "enclosure_fit", "计算外壳腔体与 PCB 的配合间隙（负值为干涉）", enclosure_fit_schema, enclosureFitTool);
        try registerTool(self, registry, "design_rank", "先淘汰硬约束违规，再按代价排序候选方案", design_rank_schema, designRankTool);
        try registerTool(self, registry, "skill_list", "列出当前可用技能（工作区与运行时记忆）", skill_list_schema, skillListTool);
    }
};

const project_open_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"}},\"required\":[\"id\"]}";
const set_constraint_schema = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\"},\"id\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\"},\"limit\":{\"type\":\"number\"},\"direction\":{\"type\":\"string\"},\"severity\":{\"type\":\"string\"}},\"required\":[\"project\",\"id\",\"kind\",\"limit\"]}";
const pcb_read_schema = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"project\"]}";
const drc_check_schema = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\"}},\"required\":[\"project\"]}";
const enclosure_fit_schema = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\"},\"width\":{\"type\":\"number\"},\"height\":{\"type\":\"number\"},\"wall\":{\"type\":\"number\"},\"shell_height\":{\"type\":\"number\"},\"apply\":{\"type\":\"boolean\"}},\"required\":[\"project\",\"width\",\"height\",\"wall\"]}";
const design_rank_schema = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\"},\"candidates\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"measurements\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"},\"value\":{\"type\":\"number\"},\"ref\":{\"type\":\"string\"}}}}}}}},\"required\":[\"project\",\"candidates\"]}";
const skill_list_schema = "{\"type\":\"object\",\"properties\":{}}";

fn registerTool(ws: *Workspace, registry: *tools.Registry, name: []const u8, description: []const u8, schema_text: []const u8, execute: tools.ToolFn) !void {
    const gpa = ws.gpa;
    const schema = try ju.parseValue(gpa, schema_text);
    defer ju.freeJsonValue(gpa, schema);
    try registry.register(.{
        .name = name,
        .description = description,
        .parameters = schema,
        .plugin_id = "design",
        .execute = execute,
    });
}

fn workspaceOf(ctx: *tools.ToolCtx) !*Workspace {
    const raw = ctx.workspace orelse return error.MissingArgument;
    return @as(*Workspace, @ptrCast(@alignCast(raw)));
}

fn projectOf(ctx: *tools.ToolCtx, args: std.json.Value) !*project.DesignProject {
    const ws = try workspaceOf(ctx);
    const id = ju.objStr(args.object, "project");
    if (id.len == 0) return error.MissingArgument;
    return ws.get(id) orelse error.ProjectNotFound;
}

fn okJson(gpa: Allocator, obj: std.json.Value) !tools.ToolResult {
    const text = try ju.stringifyAlloc(gpa, obj);
    ju.freeJsonValue(gpa, obj);
    return .{ .ok = true, .content = text };
}

fn boardJson(gpa: Allocator, board: *const pcb.Board) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "width", .{ .float = board.bounds.width() });
    try ju.putKey(gpa, &obj.object, "height", .{ .float = board.bounds.height() });
    try ju.putKey(gpa, &obj.object, "trace_width", .{ .float = board.trace_width });
    try ju.putKey(gpa, &obj.object, "components", .{ .integer = @intCast(board.components.items.len) });
    try ju.putKey(gpa, &obj.object, "pads", .{ .integer = @intCast(board.pads.items.len) });
    try ju.putKey(gpa, &obj.object, "holes", .{ .integer = @intCast(board.holes.items.len) });
    try ju.putKey(gpa, &obj.object, "rat_length", .{ .float = try board.totalRatLength() });
    return obj;
}

fn projectSummary(gpa: Allocator, p: *const project.DesignProject) !std.json.Value {
    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "project", try ju.strVal(gpa, p.id));
    try ju.putKey(gpa, &obj.object, "name", try ju.strVal(gpa, p.name));
    try ju.putKey(gpa, &obj.object, "constraints", .{ .integer = @intCast(p.constraints.count()) });
    try ju.putKey(gpa, &obj.object, "board", try boardJson(gpa, &p.board));
    if (p.enclosure) |enc| {
        try ju.putKey(gpa, &obj.object, "fit_clearance", .{ .float = enc.fitClearance(&p.board) });
    }
    return obj;
}

fn numberArg(obj: std.json.ObjectMap, key: []const u8) f64 {
    const v = ju.objGet(obj, key) orelse return 0.0;
    switch (v) {
        .integer => |i| return @floatFromInt(i),
        .float => |f| return f,
        else => return 0.0,
    }
}

fn projectOpenTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    const ws = try workspaceOf(ctx);
    try ctx.policy.checkCapability(.design_edit);
    const id = ju.objStr(args.object, "id");
    if (id.len == 0) return error.MissingArgument;
    const p = try ws.open(id, ju.objStr(args.object, "name"));
    return okJson(gpa, try projectSummary(gpa, p));
}

fn setConstraintTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.design_edit);
    const p = try projectOf(ctx, args);

    const kind = constraints.kindFromString(ju.objStr(args.object, "kind")) orelse return error.UnknownKind;
    const direction = constraints.directionFromString(ju.objStr(args.object, "direction")) orelse .min;
    const severity = constraints.severityFromString(ju.objStr(args.object, "severity")) orelse .hard;
    const limit = numberArg(args.object, "limit");
    const rule_id = try gpa.dupe(u8, ju.objStr(args.object, "id"));
    defer gpa.free(rule_id);

    try p.constraints.add(.{
        .id = rule_id,
        .kind = kind,
        .limit = limit,
        .direction = direction,
        .severity = severity,
    });

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "project", try ju.strVal(gpa, p.id));
    try ju.putKey(gpa, &obj.object, "rule", try ju.strVal(gpa, rule_id));
    try ju.putKey(gpa, &obj.object, "kind", try ju.strVal(gpa, @tagName(kind)));
    try ju.putKey(gpa, &obj.object, "severity", try ju.strVal(gpa, @tagName(severity)));
    try ju.putKey(gpa, &obj.object, "limit", .{ .float = limit });
    return okJson(gpa, obj);
}

fn pcbReadTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.read_file);
    const p = try projectOf(ctx, args);

    var text: []const u8 = ju.objStr(args.object, "text");
    var owned: ?[]const u8 = null;
    defer if (owned) |o| gpa.free(o);

    if (text.len == 0) {
        const path = ju.objStr(args.object, "path");
        if (path.len == 0) return error.MissingArgument;
        try ctx.policy.checkPath(path);
        owned = try std.fs.cwd().readFileAlloc(gpa, path, max_read_bytes);
        text = owned.?;
    }

    const board = try kicad.readBoard(gpa, text);
    p.board.deinit();
    p.board = board;
    return okJson(gpa, try projectSummary(gpa, p));
}

fn drcCheckTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.run_tool);
    const p = try projectOf(ctx, args);
    const report = try validation.runDrc(gpa, &p.board, &p.constraints);
    defer report.free();
    return okJson(gpa, try report.toJson());
}

fn enclosureFitTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.design_edit);
    const p = try projectOf(ctx, args);

    const w = numberArg(args.object, "width");
    const h = numberArg(args.object, "height");
    const wall = numberArg(args.object, "wall");
    const shell_height = numberArg(args.object, "shell_height");

    const enc = project.Enclosure{
        .name = try gpa.dupe(u8, "enclosure"),
        .outer = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = w, .y = h } },
        .wall = wall,
        .height = shell_height,
    };
    defer gpa.free(enc.name);

    const clearance = enc.fitClearance(&p.board);
    if (ju.objGet(args.object, "apply")) |v| {
        if (v == .bool and v.bool) try p.setEnclosure(enc);
    }

    var obj = ju.newObj(gpa);
    errdefer ju.freeJsonValue(gpa, obj);
    try ju.putKey(gpa, &obj.object, "project", try ju.strVal(gpa, p.id));
    try ju.putKey(gpa, &obj.object, "cavity_area", .{ .float = enc.cavity().area() });
    try ju.putKey(gpa, &obj.object, "fit_clearance", .{ .float = clearance });
    try ju.putKey(gpa, &obj.object, "fits", .{ .bool = clearance >= 0.0 });
    return okJson(gpa, obj);
}

fn designRankTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.run_tool);
    const p = try projectOf(ctx, args);

    const candidates_v = ju.objGet(args.object, "candidates") orelse return error.MissingArgument;
    if (candidates_v != .array) return error.MissingArgument;

    var parsed: std.ArrayList(constraints.Candidate) = .empty;
    defer {
        for (parsed.items) |c| {
            gpa.free(c.id);
            for (c.measurements) |m| gpa.free(m.ref);
            gpa.free(c.measurements);
        }
        parsed.deinit(gpa);
    }

    for (candidates_v.array.items) |cv| {
        if (cv != .object) continue;
        const item = cv.object;
        var measures: std.ArrayList(constraints.Measurement) = .empty;
        errdefer {
            for (measures.items) |m| gpa.free(m.ref);
            measures.deinit(gpa);
        }
        if (ju.objGet(item, "measurements")) |mv| {
            if (mv == .array) {
                for (mv.array.items) |entry| {
                    if (entry != .object) continue;
                    const kind = constraints.kindFromString(ju.objStr(entry.object, "kind")) orelse continue;
                    try measures.append(gpa, .{
                        .kind = kind,
                        .value = numberArg(entry.object, "value"),
                        .ref = try gpa.dupe(u8, ju.objStr(entry.object, "ref")),
                    });
                }
            } else if (mv == .object) {
                // 基准文件形态：measurements 是 kind -> 数值 的映射，ref 用候选 id。
                var it = mv.object.iterator();
                while (it.next()) |e| {
                    const kind = constraints.kindFromString(e.key_ptr.*) orelse continue;
                    try measures.append(gpa, .{
                        .kind = kind,
                        .value = numberArg(mv.object, e.key_ptr.*),
                        .ref = try gpa.dupe(u8, ju.objStr(item, "id")),
                    });
                }
            }
        }
        try parsed.append(gpa, .{
            .id = try gpa.dupe(u8, ju.objStr(item, "id")),
            .measurements = try measures.toOwnedSlice(gpa),
        });
    }

    const ranked = try constraints.rank(gpa, &p.constraints, parsed.items);
    defer {
        gpa.free(ranked);
    }

    var arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, arr);
    for (ranked) |r| {
        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "id", try ju.strVal(gpa, r.id));
        try ju.putKey(gpa, &item.object, "eliminated", .{ .bool = r.eliminated });
        try ju.putKey(gpa, &item.object, "hard_violations", .{ .integer = @intCast(r.hard_violations) });
        try ju.putKey(gpa, &item.object, "soft_penalty", .{ .integer = @intCast(r.soft_penalty) });
        try ju.putKey(gpa, &item.object, "optimization_cost", .{ .float = r.optimization_cost });
        try arr.array.append(item);
    }
    return okJson(gpa, arr);
}

fn skillListTool(ctx: *tools.ToolCtx, args: std.json.Value) anyerror!tools.ToolResult {
    const gpa = ctx.gpa;
    try ctx.policy.checkCapability(.run_tool);
    const ws = try workspaceOf(ctx);
    _ = args;

    var arr = ju.newArr(gpa);
    errdefer ju.freeJsonValue(gpa, arr);
    for (ws.skills.items) |s| {
        var item = ju.newObj(gpa);
        errdefer ju.freeJsonValue(gpa, item);
        try ju.putKey(gpa, &item.object, "name", try ju.strVal(gpa, s.name));
        try ju.putKey(gpa, &item.object, "version", try ju.strVal(gpa, s.version));
        try ju.putKey(gpa, &item.object, "summary", try ju.strVal(gpa, s.summary));
        try arr.array.append(item);
    }
    if (ws.runtime) |rt| {
        for (rt.skills.items) |s| {
            var item = ju.newObj(gpa);
            errdefer ju.freeJsonValue(gpa, item);
            try ju.putKey(gpa, &item.object, "name", try ju.strVal(gpa, s.name));
            try ju.putKey(gpa, &item.object, "version", try ju.strVal(gpa, s.version));
            try ju.putKey(gpa, &item.object, "summary", try ju.strVal(gpa, s.body));
            try arr.array.append(item);
        }
    }
    return okJson(gpa, arr);
}

// --- 测试 ---

fn testCtx(gpa: Allocator, policy: *sandbox.Policy, ws: *Workspace) tools.ToolCtx {
    return .{ .gpa = gpa, .policy = policy, .workspace = @ptrCast(ws) };
}

test "design tools registered" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);
    try std.testing.expectEqual(@as(usize, 7), reg.count());
    try std.testing.expect(reg.tools.get("drc_check") != null);
}

test "design tool: drc reports violation through registry" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    try policy.grant(.design_edit);
    try policy.grant(.read_file);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const p = try ws.open("p1", "sensor-node");
    p.board.bounds = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 40, .y = 30 } };
    p.board.trace_width = 0.2;

    var ctx = testCtx(gpa, &policy, &ws);
    const set_args = try ju.parseValue(gpa, "{\"project\":\"p1\",\"id\":\"min_trace_width\",\"kind\":\"trace_width\",\"limit\":0.3,\"direction\":\"min\",\"severity\":\"hard\"}");
    defer ju.freeJsonValue(gpa, set_args);
    const set_res = try reg.execute(&ctx, "project_set_constraint", set_args);
    defer set_res.free(gpa);
    try std.testing.expect(set_res.ok);
    try std.testing.expectEqual(@as(usize, 1), p.constraints.count());

    const check_args = try ju.parseValue(gpa, "{\"project\":\"p1\"}");
    defer ju.freeJsonValue(gpa, check_args);
    const drc = try reg.execute(&ctx, "drc_check", check_args);
    defer drc.free(gpa);
    try std.testing.expect(std.mem.indexOf(u8, drc.content, "\"hard_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, drc.content, "\"passed\":false") != null);
}

test "design tool: enclosure fit and hard elimination ranking" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    try policy.grant(.design_edit);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const p = try ws.open("p2", "box");
    p.board.bounds = .{ .min = .{ .x = 4, .y = 4 }, .max = .{ .x = 44, .y = 34 } };
    try p.constraints.add(.{ .id = "drc_clean", .kind = .drc_errors, .limit = 0, .direction = .max, .severity = .hard });
    try p.constraints.add(.{ .id = "rat", .kind = .rat_length, .limit = 700, .direction = .max, .severity = .soft });

    var ctx = testCtx(gpa, &policy, &ws);
    const fit_args = try ju.parseValue(gpa, "{\"project\":\"p2\",\"width\":48,\"height\":38,\"wall\":2,\"shell_height\":12,\"apply\":true}");
    defer ju.freeJsonValue(gpa, fit_args);
    const fit = try reg.execute(&ctx, "enclosure_fit", fit_args);
    defer fit.free(gpa);
    try std.testing.expect(std.mem.indexOf(u8, fit.content, "\"fits\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, fit.content, "\"fit_clearance\":2") != null);

    const rank_args = try ju.parseValue(gpa, "{\"project\":\"p2\",\"candidates\":[{\"id\":\"A\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"a\"},{\"kind\":\"rat_length\",\"value\":820,\"ref\":\"a\"}]},{\"id\":\"B\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":0,\"ref\":\"b\"},{\"kind\":\"rat_length\",\"value\":670,\"ref\":\"b\"}]},{\"id\":\"C\",\"measurements\":[{\"kind\":\"drc_errors\",\"value\":3,\"ref\":\"c\"},{\"kind\":\"rat_length\",\"value\":590,\"ref\":\"c\"}]}]}");
    defer ju.freeJsonValue(gpa, rank_args);
    const ranked = try reg.execute(&ctx, "design_rank", rank_args);
    defer ranked.free(gpa);
    // 硬约束先淘汰：C 虽然飞线最短仍出局，B 排在 A 之前
    try std.testing.expect(std.mem.indexOf(u8, ranked.content, "{\"id\":\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranked.content, "\"eliminated\":true") != null);
}

test "design tool: pcb read from text" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    try policy.grant(.design_edit);
    try policy.grant(.read_file);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    const p = try ws.open("p3", "kicad-import");
    try std.testing.expectEqualStrings("kicad-import", p.name);
    var ctx = testCtx(gpa, &policy, &ws);
    const args = try ju.parseValue(gpa, "{\"project\":\"p3\",\"text\":\"(kicad_pcb (segment (start 0 0) (end 40 0) (width 0.2) (layer \\\"Edge.Cuts\\\")) (footprint \\\"QFP\\\" (at 10 10 0) (property \\\"Reference\\\" \\\"U1\\\" (at 10 10 0)) (pad 1 smd rect (at 0 0) (size 0.5 0.5) (layers F_Cu) (net 1 \\\"GND\\\"))))\"}");
    defer ju.freeJsonValue(gpa, args);
    const res = try reg.execute(&ctx, "pcb_read", args);
    defer res.free(gpa);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "\"components\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "\"pads\":1") != null);
}

test "design tool: skill list merges runtime memory" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);

    try ws.addSkill("pcb-layout", "1.0.0", "关键连接器优先定位");
    var rt = claw.ClawRuntime.init(gpa);
    defer rt.deinit();
    ws.runtime = &rt;
    try rt.addSkillCopy(.{ .name = "enclosure-design", .version = "0.2.0", .preconditions = "", .prohibitions = "", .body = "保留 USB-C 开孔" });

    var ctx = testCtx(gpa, &policy, &ws);
    const args = try ju.parseValue(gpa, "{}");
    defer ju.freeJsonValue(gpa, args);
    const res = try reg.execute(&ctx, "skill_list", args);
    defer res.free(gpa);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "pcb-layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "enclosure-design") != null);
}

test "design tool: capability denied" {
    const gpa = std.testing.allocator;
    var policy = sandbox.Policy.init(gpa, "ws");
    try policy.grant(.run_tool);
    var ws = Workspace.init(gpa, &policy);
    defer ws.deinit();
    var reg = tools.Registry.init(gpa);
    defer reg.deinit();
    try ws.registerTools(&reg);
    _ = try ws.open("p4", "x");

    var ctx = testCtx(gpa, &policy, &ws);
    const args = try ju.parseValue(gpa, "{\"project\":\"p4\",\"width\":45,\"height\":35,\"wall\":2}");
    defer ju.freeJsonValue(gpa, args);
    try std.testing.expectError(error.CapabilityDenied, reg.execute(&ctx, "enclosure_fit", args));
}
