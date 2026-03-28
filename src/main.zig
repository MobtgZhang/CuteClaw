const std = @import("std");
const cuteclaw = @import("cuteclaw");
const serve = @import("serve.zig");
const runtime_ops = @import("runtime_ops.zig");
const memory_cli = @import("memory_cli.zig");
const agent_tool_cli = @import("agent_tool_cli.zig");

const ProposalFile = struct {
    skill_name: []const u8,
    version_hint: []const u8 = "",
    patch_summary: []const u8,
    new_body: []const u8,
    preconditions: []const u8 = "",
    prohibitions: []const u8 = "",
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var out_buf: [16384]u8 = undefined;
    var out_wr = std.fs.File.stdout().writer(&out_buf);
    const out = &out_wr.interface;

    var err_buf: [1024]u8 = undefined;
    var err_wr = std.fs.File.stderr().writer(&err_buf);
    const err = &err_wr.interface;

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    if (argv.len < 2) {
        try printHelp(out);
        try out.flush();
        return;
    }
    const cmd = argv[1];
    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        try printHelp(out);
        try out.flush();
        return;
    }
    if (eql(cmd, "version") or eql(cmd, "-V")) {
        try out.print("CuteClaw {s} (Zig)\n", .{cuteclaw.version});
        try out.flush();
        return;
    }

    if (eql(cmd, "demo")) {
        try cmdDemo(gpa, out, argv);
        try out.flush();
        return;
    }
    if (eql(cmd, "init")) {
        try cmdInit(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "status")) {
        try cmdStatus(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "export")) {
        try cmdExport(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "import")) {
        try cmdImport(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "evolve")) {
        try cmdEvolve(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "validate")) {
        try cmdValidate(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "task")) {
        try cmdTask(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "invoke")) {
        try cmdInvoke(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "serve")) {
        try cmdServe(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "working")) {
        try cmdWorking(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "fact")) {
        try cmdFact(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "memory")) {
        try memory_cli.cmdMemory(gpa, out, err, argv);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "agent-tool")) {
        try agent_tool_cli.cmdAgentTool(gpa, out, err);
        try out.flush();
        try err.flush();
        return;
    }
    if (eql(cmd, "config")) {
        if (argv.len < 3) {
            try err.print("用法: config show | init | validate [--force 仅 init]\n", .{});
            try err.flush();
            std.process.exit(2);
        }
        const sub = argv[2];
        if (eql(sub, "show")) {
            try cmdConfigShow(gpa, out, err, argv);
        } else if (eql(sub, "init")) {
            try cmdConfigInit(gpa, out, err, argv);
        } else if (eql(sub, "validate")) {
            try cmdConfigValidate(gpa, out, err, argv);
        } else {
            try err.print("未知 config 子命令: {s}（支持 show / init / validate）\n", .{sub});
            try err.flush();
            std.process.exit(2);
        }
        try out.flush();
        try err.flush();
        return;
    }

    try err.print("未知子命令: {s}\n", .{cmd});
    try err.flush();
    try printHelp(out);
    try out.flush();
    std.process.exit(1);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn flagValue(argv: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        if (eql(argv[i], name) and i + 1 < argv.len)
            return argv[i + 1];
    }
    return null;
}

fn hasFlag(argv: []const []const u8, name: []const u8) bool {
    for (argv[2..]) |a| {
        if (eql(a, name)) return true;
    }
    return false;
}

fn resolveStorePath(gpa: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    if (flagValue(argv, "--store")) |p| {
        return try gpa.dupe(u8, p);
    }
    if (std.process.getEnvVarOwned(gpa, "CUTECLAW_STORE")) |p| return p else |_| {}
    return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cuteclaw.config.default_data_dir, cuteclaw.config.default_store_file });
}

fn resolveConfigPath(gpa: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    if (flagValue(argv, "--config")) |p| {
        return try gpa.dupe(u8, p);
    }
    if (std.process.getEnvVarOwned(gpa, "CUTECLAW_CONFIG")) |p| return p else |_| {}
    return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cuteclaw.config.default_data_dir, cuteclaw.config.default_config_file });
}

fn printHelp(out: anytype) !void {
    try out.writeAll(
        \\CuteClaw — 自进化 Agent 核心（CLI，无 UI）
        \\
        \\全局选项（多数子命令可用）:
        \\  --store PATH    快照路径（默认 .cuteclaw/store.json，或 CUTECLAW_STORE）
        \\  --config PATH   API 配置路径（默认 .cuteclaw/config.json，或 CUTECLAW_CONFIG）
        \\
        \\子命令:
        \\  demo            演示：情景记忆 + 进化合并 + 可选持久化
        \\  init [--force]  创建数据目录并写入空快照
        \\  status          加载快照并打印统计
        \\  export          将快照 JSON 打印到 stdout
        \\  import          从 stdin 读入 JSON 快照并写入 --store
        \\  evolve          从 --file 读取提议，合并后保存（需 --policy --semver）；权威实现见 Zig，Web 仅为可选 UI
        \\  memory          管理 Agent cache 下 memory：list | get | put | rm（--cache --project）
        \\  validate        校验提议 JSON（--file）
        \\  task            追加情景记录: task <id> <outcome> <summary...>
        \\  invoke          记录技能调用统计: invoke <skill_name> <ok|fail>
        \\  serve [--port N] 仅 127.0.0.1 HTTP（/health、/api/* 等）；端口默认 8788 或 CUTECLAW_SERVE_PORT；日志在 stderr
        \\  working show | working set <field> <文本...>   查看/更新工作区（field: goal|constraints|confirmed_facts|next_step）
        \\  fact add <key> <value...>  追加语义事实（confidence 固定 1.0）
        \\  config show     打印 API 配置（不输出密钥内容）
        \\  config init     写入默认 config.json（已存在时需 --force）
        \\  config validate 校验 config.json 字段（与库解析一致）
        \\  version / help
        \\
        \\退出码: 0 成功；1 校验/业务拒绝；2 用法或 I/O/解析失败（详见 docs/cli-exit-codes.md）
        \\
        \\示例:
        \\  zig build run -- init
        \\  zig build run -- demo
        \\  zig build run -- evolve --file examples/proposal.json --policy auto_append_only --semver 0.3.0
        \\
    );
}

fn cmdDemo(gpa: std.mem.Allocator, out: anytype, argv: []const []const u8) !void {
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();

    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    try rt.rememberEpisode(.{
        .task_id = "demo-cli",
        .ended_unix = std.time.timestamp(),
        .summary = "CLI demo 运行",
        .outcome = .success,
    });

    const proposal: cuteclaw.evolution.Proposal = .{
        .skill_name = "email_login",
        .version_hint = "next",
        .patch_summary = "增加 OTP 等待步骤",
        .new_body =
        \\1. 打开登录页
        \\2. 提交账号密码
        \\3. 若出现 OTP 输入框，等待用户输入后再提交
        ,
        .preconditions = "需要已配置的浏览器会话",
        .prohibitions = "禁止在日志中打印密码",
    };

    const ts = std.time.timestamp();
    if (rt.findSkillLast("email_login") == null) {
        _ = try rt.applyProposal(proposal, .auto_append_only, "0.1.0", ts);
    } else {
        try out.print("(技能 email_login 已存在，跳过重复合并)\n", .{});
    }

    var wbuf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&wbuf);
    const demo_ws = cuteclaw.working.WorkingSet{
        .goal = "沉淀可复用登录规程",
        .next_step = "观测后续任务成功率",
    };
    try demo_ws.formatBlock(fbs.writer());

    try out.print("{s}\n", .{fbs.getWritten()});
    try out.print("情景: {}  技能: {}  事实: {}  审计: {}\n", .{
        rt.episodic.items.len,
        rt.skills.items.len,
        rt.facts.items.len,
        rt.metrics.audit.items.len,
    });
    try out.print("已写入: {s}\n", .{store});
    try cuteclaw.persist.saveToPath(&rt, gpa, store, ts);
}

fn cmdInit(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);
    const force = hasFlag(argv, "--force");

    var exists = false;
    if (std.fs.cwd().access(store, .{})) |_| {
        exists = true;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    if (exists and !force) {
        try err.print("快照已存在，使用 --force 覆盖: {s}\n", .{store});
        std.process.exit(2);
    }

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    try cuteclaw.persist.saveToPath(&rt, gpa, store, std.time.timestamp());
    try out.print("已初始化空快照: {s}\n", .{store});
}

fn cmdStatus(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);
    const cfg_path = try resolveConfigPath(gpa, argv);
    defer gpa.free(cfg_path);

    var lk = try cuteclaw.store_lock.acquire(store, false);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| {
        try err.print("无法加载 {s}: {}（参见 docs/format.md）\n", .{ store, e });
        std.process.exit(2);
    };

    try runtime_ops.writeStatusText(out, &rt, store, cfg_path);
}

fn cmdExport(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    _ = err;
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    var lk = try cuteclaw.store_lock.acquire(store, false);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    try cuteclaw.persist.loadFromPath(&rt, gpa, store);

    const json_bytes = try cuteclaw.persist.snapshotToJsonAlloc(&rt, gpa, std.time.timestamp());
    defer gpa.free(json_bytes);
    try out.print("{s}\n", .{json_bytes});
}

fn cmdImport(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    const stdin = std.fs.File.stdin();
    const data = try stdin.readToEndAlloc(gpa, cuteclaw.persist.max_file_bytes);
    defer gpa.free(data);

    var parsed = std.json.parseFromSlice(cuteclaw.persist.StoreDocumentV1, gpa, data, .{ .ignore_unknown_fields = true }) catch |e| {
        try err.print("import: JSON 解析失败: {}（格式见 docs/format.md）\n", .{e});
        std.process.exit(2);
    };
    defer parsed.deinit();

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    try cuteclaw.persist.applyLoadedDocument(&rt, parsed.value);
    try cuteclaw.persist.saveToPath(&rt, gpa, store, std.time.timestamp());
    try out.print("已自 stdin 导入并写入 {s}\n", .{store});
}

fn cmdEvolve(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const file_path = flagValue(argv, "--file") orelse {
        try err.print("需要 --file proposal.json\n", .{});
        std.process.exit(2);
    };
    const policy_s = flagValue(argv, "--policy") orelse {
        try err.print("需要 --policy dry_run|auto_append_only|require_human\n", .{});
        std.process.exit(2);
    };
    const semver = flagValue(argv, "--semver") orelse {
        try err.print("需要 --semver 如 1.0.0\n", .{});
        std.process.exit(2);
    };
    const policy = cuteclaw.evolution.policyFromString(policy_s) orelse {
        try err.print("未知策略: {s}\n", .{policy_s});
        std.process.exit(2);
    };

    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    const raw = try std.fs.cwd().readFileAlloc(gpa, file_path, cuteclaw.persist.max_file_bytes);
    defer gpa.free(raw);

    var pj = try std.json.parseFromSlice(ProposalFile, gpa, raw, .{ .ignore_unknown_fields = true });
    defer pj.deinit();

    const p: cuteclaw.evolution.Proposal = .{
        .skill_name = pj.value.skill_name,
        .version_hint = pj.value.version_hint,
        .patch_summary = pj.value.patch_summary,
        .new_body = pj.value.new_body,
        .preconditions = pj.value.preconditions,
        .prohibitions = pj.value.prohibitions,
    };

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    const ts = std.time.timestamp();
    const d = try rt.applyProposal(p, policy, semver, ts);

    switch (d) {
        .accepted => |s| try out.print("已接受: {s}@{s}\n", .{ s.name, s.version }),
        .rejected => |r| try out.print("拒绝: {s}\n", .{r}),
        .deferred => try out.print("推迟（dry_run 或需人工）\n", .{}),
    }
    try cuteclaw.persist.saveToPath(&rt, gpa, store, ts);
}

fn cmdValidate(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    _ = err;
    const file_path = flagValue(argv, "--file") orelse {
        try out.print("需要 --file\n", .{});
        std.process.exit(2);
    };
    const raw = try std.fs.cwd().readFileAlloc(gpa, file_path, cuteclaw.persist.max_file_bytes);
    defer gpa.free(raw);
    var pj = try std.json.parseFromSlice(ProposalFile, gpa, raw, .{ .ignore_unknown_fields = true });
    defer pj.deinit();
    const p: cuteclaw.evolution.Proposal = .{
        .skill_name = pj.value.skill_name,
        .version_hint = pj.value.version_hint,
        .patch_summary = pj.value.patch_summary,
        .new_body = pj.value.new_body,
        .preconditions = pj.value.preconditions,
        .prohibitions = pj.value.prohibitions,
    };
    cuteclaw.evolution.checkProposal(p) catch |e| {
        try out.print("checkProposal: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    try out.print("checkProposal: ok\n", .{});
}

fn cmdTask(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    if (argv.len < 5) {
        try err.print("用法: task <task_id> <outcome> <summary...>\n", .{});
        std.process.exit(2);
    }
    const task_id = argv[2];
    const oc = cuteclaw.memory.outcomeFromString(argv[3]) orelse {
        try err.print("outcome 须为 success|failed|aborted|needs_human\n", .{});
        std.process.exit(2);
    };
    const summary = try std.mem.join(gpa, " ", argv[4..]);
    defer gpa.free(summary);

    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    try rt.rememberEpisode(.{
        .task_id = task_id,
        .ended_unix = std.time.timestamp(),
        .summary = summary,
        .outcome = oc,
    });
    const ts = std.time.timestamp();
    try cuteclaw.persist.saveToPath(&rt, gpa, store, ts);
    try out.print("已追加情景并保存\n", .{});
}

fn cmdInvoke(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    if (argv.len < 4) {
        try err.print("用法: invoke <skill_name> <ok|fail>\n", .{});
        std.process.exit(2);
    }
    const name = argv[2];
    const ok = eql(argv[3], "ok");
    if (!ok and !eql(argv[3], "fail")) {
        try err.print("第三参数须为 ok 或 fail\n", .{});
        std.process.exit(2);
    }

    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    try rt.metrics.recordSkillInvocation(name, ok, std.time.timestamp());
    try cuteclaw.persist.saveToPath(&rt, gpa, store, std.time.timestamp());
    try out.print("已记录技能调用: {s} success={}\n", .{ name, ok });
}

fn cmdConfigShow(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    _ = err;
    const path = try resolveConfigPath(gpa, argv);
    defer gpa.free(path);
    try runtime_ops.writeConfigShowText(gpa, out, path);
}

fn cmdConfigInit(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const path = try resolveConfigPath(gpa, argv);
    defer gpa.free(path);
    const force = hasFlag(argv, "--force");

    var exists = false;
    if (std.fs.cwd().access(path, .{})) |_| {
        exists = true;
    } else |_| {}
    if (exists and !force) {
        try err.print("配置已存在，使用 --force 覆盖: {s}\n", .{path});
        std.process.exit(2);
    }

    try cuteclaw.config.writeDefaultApiConfigToPath(gpa, path);
    try out.print("已写入默认 API 配置: {s}\n", .{path});
}

fn cmdConfigValidate(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const path = try resolveConfigPath(gpa, argv);
    defer gpa.free(path);

    var cfg = cuteclaw.config.loadApiConfigFromPath(gpa, path) catch |e| {
        try err.print("config validate: {s} ({s})\n", .{ @errorName(e), path });
        switch (e) {
            error.FileNotFound => std.process.exit(2),
            error.UnsupportedApiConfigSchema => std.process.exit(1),
            else => std.process.exit(2),
        }
    };
    defer cfg.deinit(gpa);
    try out.print("config validate: ok ({s})\n", .{path});
}

fn cmdServe(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);
    const cfg_path = try resolveConfigPath(gpa, argv);
    defer gpa.free(cfg_path);

    var port: u16 = 8788;
    if (flagValue(argv, "--port")) |ps| {
        port = try std.fmt.parseInt(u16, ps, 10);
    } else {
        if (std.process.getEnvVarOwned(gpa, "CUTECLAW_SERVE_PORT")) |ep| {
            defer gpa.free(ep);
            port = try std.fmt.parseInt(u16, ep, 10);
        } else |_| {}
    }
    const exe_path: []const u8 = if (argv.len > 0) argv[0] else "cuteclaw";
    try serve.run(gpa, store, cfg_path, port, exe_path, out, err);
}

fn cmdWorking(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    if (argv.len < 3) {
        try err.print("用法: working show | working set <goal|constraints|confirmed_facts|next_step> <文本...>\n", .{});
        std.process.exit(2);
    }
    const sub = argv[2];
    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    if (eql(sub, "show")) {
        var lk = try cuteclaw.store_lock.acquire(store, false);
        defer lk.deinit();
        var rt = cuteclaw.ClawRuntime.init(gpa);
        defer rt.deinit();
        cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
            error.FileNotFound => {
                try out.print("(尚无快照: {s})\n", .{store});
                return;
            },
            else => return e,
        };
        if (rt.working.isEmpty()) {
            try out.print("(working 为空)\n", .{});
        } else {
            var wbuf: [512]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&wbuf);
            try rt.working.formatBlock(fbs.writer());
            try out.print("{s}\n", .{fbs.getWritten()});
        }
        return;
    }
    if (!eql(sub, "set")) {
        try err.print("未知 working 子命令: {s}\n", .{sub});
        std.process.exit(2);
    }
    if (argv.len < 5) {
        try err.print("用法: working set <field> <文本...>\n", .{});
        std.process.exit(2);
    }
    const field = argv[3];
    if (!eql(field, "goal") and !eql(field, "constraints") and
        !eql(field, "confirmed_facts") and !eql(field, "next_step"))
    {
        try err.print("field 须为 goal|constraints|confirmed_facts|next_step\n", .{});
        std.process.exit(2);
    }
    const text = try std.mem.join(gpa, " ", argv[4..]);
    defer gpa.free(text);

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();
    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    try rt.setWorking(.{
        .goal = if (eql(field, "goal")) text else rt.working.goal,
        .constraints = if (eql(field, "constraints")) text else rt.working.constraints,
        .confirmed_facts = if (eql(field, "confirmed_facts")) text else rt.working.confirmed_facts,
        .next_step = if (eql(field, "next_step")) text else rt.working.next_step,
    });
    try cuteclaw.persist.saveToPath(&rt, gpa, store, std.time.timestamp());
    try out.print("已更新 working 并保存\n", .{});
}

fn cmdFact(gpa: std.mem.Allocator, out: anytype, err: anytype, argv: []const []const u8) !void {
    if (argv.len < 4 or !eql(argv[2], "add")) {
        try err.print("用法: fact add <key> <value...>\n", .{});
        std.process.exit(2);
    }
    if (argv.len < 5) {
        try err.print("用法: fact add <key> <value...>\n", .{});
        std.process.exit(2);
    }
    const key = argv[3];
    const value = try std.mem.join(gpa, " ", argv[4..]);
    defer gpa.free(value);

    const store = try resolveStorePath(gpa, argv);
    defer gpa.free(store);

    var lk = try cuteclaw.store_lock.acquire(store, true);
    defer lk.deinit();
    var rt = cuteclaw.ClawRuntime.init(gpa);
    defer rt.deinit();
    cuteclaw.persist.loadFromPath(&rt, gpa, store) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    try rt.addFact(.{ .key = key, .value = value, .confidence = 1.0 });
    try cuteclaw.persist.saveToPath(&rt, gpa, store, std.time.timestamp());
    try out.print("已追加事实并保存\n", .{});
}
