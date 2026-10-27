//! Agent 宿主（唯一控制平面）：把沙箱策略、工具注册表、事件总线、插件内核、
//! LLM 客户端与设计工作区装配成一套可被 CLI / HTTP / WebSocket 复用的运行状态。

const std = @import("std");
const ju = @import("core/jsonutil.zig");
const llm = @import("core/llm.zig");
const tools = @import("core/tools.zig");
const events = @import("core/events.zig");
const memory = @import("memory.zig");
const config = @import("config.zig");
const claw = @import("claw.zig");
const sandbox = @import("sandbox/policy.zig");
const kernel = @import("plugins/kernel.zig");
const manifest = @import("plugins/manifest.zig");
const design_tools = @import("design/tools.zig");
const graph_tools = @import("graph/tools.zig");
const loop_tools = @import("loop/tools.zig");
const http = @import("server/http.zig");
const ioc = @import("ioctx");

const Allocator = std.mem.Allocator;

pub const default_capabilities = [_]sandbox.Capability{
    .read_file,
    .write_file,
    .run_tool,
    .network,
    .plugin_exec,
    .design_edit,
    .evolve_write,
};

pub const Options = struct {
    workspace_root: []const u8 = ".",
    event_log_path: []const u8 = "",
    system_prompt: []const u8 = http.default_system_prompt,
    max_rounds: usize = 12,
    capabilities: []const sandbox.Capability = &default_capabilities,
};

/// 插件清单解析器：测试与离线场景可注入，避免依赖磁盘。
pub const PluginResolver = struct {
    ctx: *anyopaque = undefined,
    resolve: *const fn (ctx: *anyopaque, gpa: Allocator, plugin_path: []const u8) anyerror!?[]const u8,
};

pub const Host = struct {
    gpa: Allocator,
    policy: sandbox.Policy,
    registry: tools.Registry,
    bus: events.EventBus,
    kernel: kernel.Kernel,
    client: llm.Client,
    workspace: design_tools.Workspace,
    graph: graph_tools.Workspace,
    loop: loop_tools.Workspace,
    runtime: claw.ClawRuntime,
    event_log: events.EventLog,
    system_prompt: []const u8,
    max_rounds: usize,
    api_key: []const u8,
    headers: []std.http.Header,
    api_base: []const u8,
    model: []const u8,

    /// Host 内部持有指向自身子模块的指针，必须分配在堆上，返回值副本会造成悬垂指针。
    pub fn init(gpa: Allocator, llm_config: llm.Config, opts: Options) !*Host {
        const host = try gpa.create(Host);
        errdefer gpa.destroy(host);

        host.* = .{
            .gpa = gpa,
            .policy = undefined,
            .registry = undefined,
            .bus = undefined,
            .kernel = undefined,
            .client = undefined,
            .workspace = undefined,
            .graph = undefined,
            .loop = undefined,
            .runtime = undefined,
            .event_log = undefined,
            .system_prompt = undefined,
            .max_rounds = undefined,
            .api_key = &.{},
            .headers = &.{},
            .api_base = &.{},
            .model = &.{},
        };
        errdefer host.deinit();

        host.policy = sandbox.Policy.init(gpa, opts.workspace_root);
        host.registry = tools.Registry.init(gpa);
        host.bus = events.EventBus.init(gpa);
        host.kernel = kernel.Kernel.init(gpa, &host.registry);
        host.workspace = design_tools.Workspace.init(gpa, &host.policy);
        host.graph = graph_tools.Workspace.init(gpa, &host.policy);
        host.loop = try loop_tools.Workspace.init(gpa, &host.policy);
        host.runtime = claw.ClawRuntime.init(gpa);
        host.event_log = events.EventLog.init(gpa, opts.event_log_path);
        host.system_prompt = opts.system_prompt;
        host.max_rounds = opts.max_rounds;
        // Host 必须持有自己的配置副本：调用方释放 llm_config 后仍可安全使用。
        host.api_key = try gpa.dupe(u8, llm_config.api_key);
        host.api_base = try gpa.dupe(u8, llm_config.api_base);
        host.model = try gpa.dupe(u8, llm_config.model);
        host.headers = try gpa.alloc(std.http.Header, llm_config.extra_headers.len);
        for (llm_config.extra_headers, 0..) |h, i| {
            host.headers[i] = .{ .name = try gpa.dupe(u8, h.name), .value = try gpa.dupe(u8, h.value) };
        }
        host.client = llm.Client.init(gpa, .{
            .provider = llm_config.provider,
            .api_base = host.api_base,
            .api_key = host.api_key,
            .model = host.model,
            .connect_timeout_ms = llm_config.connect_timeout_ms,
            .read_timeout_ms = llm_config.read_timeout_ms,
            .temperature = llm_config.temperature,
            .top_p = llm_config.top_p,
            .max_tokens = llm_config.max_tokens,
            .extra_headers = host.headers,
        });
        host.kernel.bus = &host.bus;
        host.workspace.runtime = &host.runtime;
        host.graph.runtime = &host.runtime;
        host.graph.design = &host.workspace;

        for (opts.capabilities) |cap| try host.policy.grant(cap);
        try host.workspace.registerTools(&host.registry);
        try host.graph.loadBuiltinGates();
        try host.graph.registerTools(&host.registry);
        try host.loop.registerTools(&host.registry);
        return host;
    }

    pub fn deinit(self: *Host) void {
        self.loop.deinit();
        self.graph.deinit();
        self.workspace.deinit();
        self.kernel.deinit();
        self.bus.deinit();
        self.registry.deinit();
        self.runtime.deinit();
        for (self.headers) |h| {
            self.gpa.free(h.name);
            self.gpa.free(h.value);
        }
        self.gpa.free(self.headers);
        self.gpa.free(self.api_key);
        self.gpa.free(self.api_base);
        self.gpa.free(self.model);
    }

    /// 与 `init` 配对：释放子模块并回收 Host 自身。
    pub fn free(self: *Host) void {
        self.deinit();
        self.gpa.destroy(self);
    }

    pub fn deps(self: *Host) http.Deps {
        return .{
            .policy = &self.policy,
            .registry = &self.registry,
            .bus = &self.bus,
            .plugins = &self.kernel,
            .client = &self.client,
            .runtime = &self.runtime,
            .metrics = &self.runtime.metrics,
            .system_prompt = self.system_prompt,
        };
    }

    pub fn app(self: *Host) http.App {
        var result = http.App.init(self.gpa, self.deps());
        result.tool_ctx.workspace = @ptrCast(&self.workspace);
        result.tool_ctx.graph_workspace = @ptrCast(&self.graph);
        result.tool_ctx.loop_workspace = @ptrCast(&self.loop);
        result.max_rounds = self.max_rounds;
        return result;
    }

    /// 从 `config.json` 生成 LLM 配置：密钥优先取密钥文件，否则取环境变量。
    pub fn llmConfig(gpa: Allocator, cfg: *const config.ApiConfigOwned) !llm.Config {
        var out: llm.Config = .{
            .provider = llm.providerFromString(cfg.provider),
            .api_base = cfg.api_base,
            .model = cfg.model,
            .connect_timeout_ms = cfg.connect_timeout_sec * 1000,
            .read_timeout_ms = cfg.read_timeout_sec * 1000,
        };
        if (try config.loadApiKeyMaterial(gpa, cfg)) |key| out.api_key = key;
        return out;
    }

    pub fn loadPluginFromText(self: *Host, package_json_text: []const u8, root: []const u8) !void {
        const record = try self.kernel.load(package_json_text, root);
        try self.kernel.enable(record.id);
    }

    pub fn loadPlugin(self: *Host, package_json_path: []const u8) !void {
        const raw = try ioc.cwd().readFileAlloc(self.gpa, package_json_path, 256 * 1024);
        defer self.gpa.free(raw);
        try self.loadPluginFromText(std.mem.trim(u8, raw, " \t\r\n"), std.fs.path.dirname(package_json_path) orelse ".");
    }

    /// `cordis.patch.yml` 兼容入口：按序列加载插件（跳过 disabled）。
    pub fn loadPatch(self: *Host, yaml_text: []const u8, resolver: ?PluginResolver) !usize {
        const entries = try manifest.parsePatchYaml(self.gpa, yaml_text);
        defer {
            for (entries) |e| {
                self.gpa.free(e.id);
                self.gpa.free(e.plugin);
                ju.freeJsonValue(self.gpa, e.config);
            }
            self.gpa.free(entries);
        }

        var loaded: usize = 0;
        for (entries) |e| {
            if (e.disabled) continue;
            const text = if (resolver) |r| try r.resolve(r.ctx, self.gpa, e.plugin) else blk: {
                const path = try std.fmt.allocPrint(self.gpa, "{s}/package.json", .{e.plugin});
                defer self.gpa.free(path);
                break :blk try ioc.cwd().readFileAlloc(self.gpa, path, 256 * 1024);
            };
            const t = text orelse continue;
            defer self.gpa.free(t);
            const root = try self.gpa.dupe(u8, e.plugin);
            defer self.gpa.free(root);
            try self.loadPluginFromText(t, root);
            loaded += 1;
        }
        return loaded;
    }

    pub fn recordEpisode(self: *Host, task_id: []const u8, summary: []const u8, outcome: memory.TaskOutcome) !void {
        try self.runtime.rememberEpisode(.{
            .task_id = task_id,
            .ended_unix = ioc.nowSec(),
            .outcome = outcome,
            .summary = summary,
        });
    }

    pub fn writeEvent(self: *Host, kind: []const u8, payload: std.json.Value) !void {
        if (self.event_log.path.len == 0) return;
        try self.event_log.append(.{ .kind = kind, .ts_unix = ioc.nowSec(), .payload = payload });
    }
};

test "host wires policy, tools and plugins" {
    const gpa = std.testing.allocator;
    const host = try Host.init(gpa, .{ .model = "test-model" }, .{ .workspace_root = "ws" });
    defer host.free();

    // 设计 7 + 图 5 + 回路 8：三层工具面必须都挂在同一个注册表上。
    try std.testing.expectEqual(@as(usize, 20), host.registry.count());
    try std.testing.expect(host.policy.allows(.design_edit));
    try std.testing.expect(host.policy.allows(.run_tool));
    try std.testing.expect(host.kernel.bus != null);
    try std.testing.expect(host.workspace.runtime != null);
    try std.testing.expectEqualStrings("test-model", host.client.config.model);

    var app = host.app();
    defer app.deinit();
    try std.testing.expect(app.tool_ctx.workspace != null);
    try std.testing.expect(app.tool_ctx.graph_workspace != null);
    try std.testing.expect(app.tool_ctx.loop_workspace != null);
}

test "host exposes the agent loop tool face" {
    const gpa = std.testing.allocator;
    const host = try Host.init(gpa, .{ .model = "m" }, .{});
    defer host.free();

    var app = host.app();
    defer app.deinit();

    // plan mode 只读：回路不能靠计划宣告自己有权写。
    const plan_args = try ju.parseValue(gpa, "{\"goal\":\"pcb layout\",\"mode\":\"plan\",\"tasks\":[{\"id\":\"t1\",\"title\":\"stackup\"}]}");
    defer ju.freeJsonValue(gpa, plan_args);
    const plan_res = try app.callTool("loop_plan", plan_args);
    defer ju.freeJsonValue(gpa, plan_res);
    const plan = try ju.parseValue(gpa, ju.objStr(plan_res.object, "content"));
    defer ju.freeJsonValue(gpa, plan);
    try std.testing.expectEqualStrings("plan", ju.objStr(plan.object, "mode"));
    try std.testing.expect(!plan.object.get("allows_write").?.bool);
    try std.testing.expectEqual(@as(i64, 1), plan.object.get("open").?.integer);
    try std.testing.expect(!plan.object.get("can_complete").?.bool);

    // 措辞式终止条件一律拒绝。
    const stop_args = try ju.parseValue(gpa, "{\"rule\":{\"kind\":\"prose\",\"criterion\":\"looks good enough\"},\"measurements\":[]}");
    defer ju.freeJsonValue(gpa, stop_args);
    // 措辞式终止条件不可判定：直接拒绝，不进入评估。
    try std.testing.expectError(error.ProseStopRuleRejected, app.callTool("loop_stop_check", stop_args));
}

test "host loads dsh plugin manifest" {
    const gpa = std.testing.allocator;
    const host = try Host.init(gpa, .{ .model = "m" }, .{});
    defer host.free();

    const raw = "{\"name\":\"pcb-layout\",\"version\":\"1.2.0\",\"engines\":{\"dsh\":\">=1.0.0\"},\"dsh\":{\"manifestVersion\":1,\"bundle\":\"patch\"},\"capabilities\":[\"run_tool\",\"design_edit\"]}";
    try host.loadPluginFromText(raw, "skills/pcb-layout");
    try std.testing.expectEqual(@as(usize, 1), host.kernel.enabledCount());
    try std.testing.expect(host.kernel.perms.allows("pcb-layout", .design_edit));

    const resolver = PluginResolver{ .ctx = undefined, .resolve = testResolver };
    const loaded = try host.loadPatch("- id: enclosure\n  plugin: ./skills/enclosure-design\n  config: {\"max_rounds\":6}\n", resolver);
    try std.testing.expectEqual(@as(usize, 1), loaded);
    try std.testing.expectEqual(@as(usize, 2), host.kernel.enabledCount());
}

const test_manifest_text = "{\"name\":\"enclosure-design\",\"version\":\"0.1.0\",\"dsh\":{\"manifestVersion\":1},\"capabilities\":[\"run_tool\"]}";

fn testResolver(ctx: *anyopaque, gpa: Allocator, plugin_path: []const u8) anyerror!?[]const u8 {
    _ = ctx;
    _ = plugin_path;
    return try gpa.dupe(u8, test_manifest_text);
}
test "host owns its own llm config copy" {
    const gpa = std.testing.allocator;

    const hdrs = try gpa.alloc(std.http.Header, 1);
    hdrs[0] = .{ .name = try gpa.dupe(u8, "x-test"), .value = try gpa.dupe(u8, "abc") };
    const cfg: llm.Config = .{
        .api_base = "https://example.test/v1",
        .api_key = "secret",
        .model = "m",
        .extra_headers = hdrs,
    };

    const host = try Host.init(gpa, cfg, .{});
    defer host.free();

    // 调用方释放自己的配置副本后，Host 仍必须可用。
    for (hdrs) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(hdrs);

    try std.testing.expectEqualStrings("https://example.test/v1", host.client.config.api_base);
    try std.testing.expectEqualStrings("secret", host.client.config.api_key);
    try std.testing.expectEqualStrings("m", host.client.config.model);
    try std.testing.expectEqual(@as(usize, 1), host.client.config.extra_headers.len);
    try std.testing.expectEqualStrings("abc", host.client.config.extra_headers[0].value);
}
