//! 127.0.0.1 HTTP：兼容旧路由 + 与 `web/server/index.ts` 对齐的 `/api/*`。

const std = @import("std");
const http = std.http;
const cuteclaw = @import("cuteclaw");
const runtime_ops = @import("runtime_ops.zig");

const max_body: usize = 2 * 1024 * 1024;

const ProposalPart = struct {
    skill_name: []const u8,
    version_hint: []const u8 = "",
    patch_summary: []const u8,
    new_body: []const u8,
    preconditions: []const u8 = "",
    prohibitions: []const u8 = "",
};

const EvolveReq = struct {
    proposal: ProposalPart,
    policy: []const u8,
    semver: []const u8,
};

const EvolveApiReq = struct {
    proposal: ProposalPart,
    policy: []const u8,
    semver: []const u8,
};

const ValidateApiReq = struct {
    proposal: ProposalPart,
};

const TaskApiReq = struct {
    taskId: []const u8,
    outcome: []const u8,
    summary: []const u8,
};

const InvokeApiReq = struct {
    skill: []const u8,
    ok: bool,
};

const LogLevel = enum { error_only, info };

fn logLevelFromEnv() LogLevel {
    const v = std.posix.getenv("CUTECLAW_LOG") orelse return .info;
    if (v.len == 0) return .info;
    if (std.ascii.eqlIgnoreCase(v, "error")) return .error_only;
    return .info;
}

fn jsonHeader() []const http.Header {
    return &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
}

fn targetPath(raw: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    return raw[0..q];
}

fn logTimestamp(err: anytype) !void {
    const ts = std.time.timestamp();
    try err.print("[{d}] ", .{ts});
}

fn logBanner(err: anytype, store_path: []const u8, config_path: []const u8, port: u16) !void {
    try logTimestamp(err);
    try err.print("CuteClaw serve 监听 http://127.0.0.1:{d}/\n", .{port});
    try logTimestamp(err);
    try err.print("store: {s}\n", .{store_path});
    try logTimestamp(err);
    try err.print("config: {s}\n", .{config_path});
    try logTimestamp(err);
    try err.print("日志: stderr（CUTECLAW_LOG=error 仅错误）；Ctrl+C 退出\n", .{});
    try err.flush();
}

fn accessLog(err: anytype, level: LogLevel, method: []const u8, path: []const u8, status: u16) !void {
    if (level == .error_only) return;
    try logTimestamp(err);
    try err.print("{s} {s} {d}\n", .{ method, path, status });
    try err.flush();
}

fn logHandlerError(err: anytype, e: anyerror) !void {
    try logTimestamp(err);
    try err.print("handleConnection: {s}\n", .{@errorName(e)});
    try err.flush();
}

pub fn run(
    gpa: std.mem.Allocator,
    store_path: []const u8,
    config_path: []const u8,
    port: u16,
    exe_path: []const u8,
    out: anytype,
    err: anytype,
) !void {
    const level = logLevelFromEnv();
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    try logBanner(err, store_path, config_path, port);

    try out.print("CuteClaw serve http://127.0.0.1:{d}/ （仅本机，Ctrl+C 退出）\n", .{port});
    try out.flush();

    const ctx = ServerCtx{
        .gpa = gpa,
        .store_path = store_path,
        .config_path = config_path,
        .exe_path = exe_path,
        .log_level = level,
    };

    while (true) {
        const conn = try listener.accept();
        handleConnection(err, ctx, conn) catch |e| {
            logHandlerError(err, e) catch {};
        };
        conn.stream.close();
    }
}

const ServerCtx = struct {
    gpa: std.mem.Allocator,
    store_path: []const u8,
    config_path: []const u8,
    exe_path: []const u8,
    log_level: LogLevel,
};

fn methodStr(m: http.Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .HEAD => "HEAD",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        else => "OTHER",
    };
}

fn healthJsonAllocFixed(al: std.mem.Allocator, store_path: []const u8, config_path: []const u8, exe_path: []const u8) ![]u8 {
    const root_owned: []const u8 = root: {
        if (std.process.getEnvVarOwned(al, "CUTECLAW_ROOT")) |p| break :root p else |_| {}
        break :root std.fs.cwd().realpathAlloc(al, ".") catch try al.dupe(u8, ".");
    };
    defer al.free(root_owned);

    return try std.fmt.allocPrint(al,
        \\{{"ok":true,"cuteclawRoot":{s},"bin":{s},"store":{s},"config":{s}}}
        \\
    , .{
        try std.json.Stringify.valueAlloc(al, root_owned, .{}),
        try std.json.Stringify.valueAlloc(al, exe_path, .{}),
        try std.json.Stringify.valueAlloc(al, store_path, .{}),
        try std.json.Stringify.valueAlloc(al, config_path, .{}),
    });
}

fn statusApiJsonAlloc(al: std.mem.Allocator, rt: *cuteclaw.ClawRuntime, store_path: []const u8, config_path: []const u8) ![]u8 {
    const stdout_text = try runtime_ops.allocStatusText(al, rt, store_path, config_path);
    defer al.free(stdout_text);

    const config_exists = if (std.fs.cwd().access(config_path, .{})) |_| true else |_| false;

    const parsed_fmt =
        \\{{"raw":{s},"storePath":{s},"configPath":{s},"configExists":{},"episodic":{},"skills":{},"facts":{},"tasks_recorded":{},"tasks_succeeded":{},"audit_tail":{},"rollups":{}}}
    ;
    const raw_js = try std.json.Stringify.valueAlloc(al, stdout_text, .{});
    defer al.free(raw_js);
    const sp_js = try std.json.Stringify.valueAlloc(al, store_path, .{});
    defer al.free(sp_js);
    const cp_js = try std.json.Stringify.valueAlloc(al, config_path, .{});
    defer al.free(cp_js);

    const parsed_inner = try std.fmt.allocPrint(al, parsed_fmt, .{
        raw_js,
        sp_js,
        cp_js,
        config_exists,
        rt.episodic.items.len,
        rt.skills.items.len,
        rt.facts.items.len,
        rt.metrics.tasks_recorded,
        rt.metrics.tasks_succeeded,
        rt.metrics.audit.items.len,
        rt.metrics.rollupCount(),
    });

    const out_js = try std.json.Stringify.valueAlloc(al, stdout_text, .{});
    defer al.free(out_js);

    return try std.fmt.allocPrint(al,
        \\{{"parsed":{s},"stdout":{s}}}
        \\
    , .{ parsed_inner, out_js });
}

fn readBody(al: std.mem.Allocator, request: *http.Server.Request, limit: usize) ![]u8 {
    const cl = request.head.content_length orelse return error.MissingContentLength;
    if (cl > limit) return error.BodyTooLarge;
    var body_scratch: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_scratch);
    return try body_reader.readAlloc(al, cl);
}

fn handleConnection(err: anytype, ctx: ServerCtx, conn: std.net.Server.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const al = arena.allocator();

    var recv_buf: [8192]u8 = undefined;
    var send_buf: [65536]u8 = undefined;
    var conn_reader = conn.stream.reader(&recv_buf);
    var conn_writer = conn.stream.writer(&send_buf);
    var hserv = http.Server.init(conn_reader.interface(), &conn_writer.interface);

    var request = try hserv.receiveHead();
    const path = targetPath(request.head.target);
    const method = request.head.method;
    const mstr = methodStr(method);

    var status_code: u16 = 500;

    if (method == .GET and std.mem.eql(u8, path, "/api/health")) {
        const body = try healthJsonAllocFixed(al, ctx.store_path, ctx.config_path, ctx.exe_path);
        status_code = 200;
        try request.respond(body, .{ .extra_headers = jsonHeader() });
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/api/status")) {
        var rt = cuteclaw.ClawRuntime.init(al);
        var lk = try cuteclaw.store_lock.acquire(ctx.store_path, false);
        defer lk.deinit();
        cuteclaw.persist.loadFromPath(&rt, al, ctx.store_path) catch |e| {
            status_code = 502;
            const msg = try std.fmt.allocPrint(al, "{{\"error\":\"load_failed\",\"detail\":\"{s}\"}}\n", .{@errorName(e)});
            try request.respond(msg, .{ .status = .bad_gateway, .extra_headers = jsonHeader() });
            try accessLog(err, ctx.log_level, mstr, path, status_code);
            return;
        };
        const body = try statusApiJsonAlloc(al, &rt, ctx.store_path, ctx.config_path);
        status_code = 200;
        try request.respond(body, .{ .extra_headers = jsonHeader() });
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/api/store")) {
        try getStoreCommon(al, ctx.store_path, &request, &status_code);
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/api/config-show")) {
        const txt = runtime_ops.allocConfigShowText(al, ctx.config_path) catch |e| {
            status_code = 500;
            const msg = try std.fmt.allocPrint(al, "{{\"error\":\"{s}\"}}\n", .{@errorName(e)});
            try request.respond(msg, .{ .status = .internal_server_error, .extra_headers = jsonHeader() });
            try accessLog(err, ctx.log_level, mstr, path, status_code);
            return;
        };
        const out_js = try std.json.Stringify.valueAlloc(al, txt, .{});
        defer al.free(out_js);
        const body = try std.fmt.allocPrint(al, "{{\"stdout\":{s}}}\n", .{out_js});
        status_code = 200;
        try request.respond(body, .{ .extra_headers = jsonHeader() });
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/api/config")) {
        var file = std.fs.cwd().openFile(ctx.config_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                status_code = 404;
                const p_js = try std.json.Stringify.valueAlloc(al, ctx.config_path, .{});
                const body = try std.fmt.allocPrint(al, "{{\"error\":\"config not found\",\"path\":{s}}}\n", .{p_js});
                try request.respond(body, .{ .status = .not_found, .extra_headers = jsonHeader() });
                try accessLog(err, ctx.log_level, mstr, path, status_code);
                return;
            },
            else => return e,
        };
        defer file.close();
        const raw = try file.readToEndAlloc(al, cuteclaw.config.max_config_file_bytes);
        status_code = 200;
        try request.respond(raw, .{ .extra_headers = jsonHeader() });
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .PUT and std.mem.eql(u8, path, "/api/config")) {
        const body_bytes = readBody(al, &request, max_body) catch {
            status_code = 400;
            try request.respond("{\"error\":\"need body\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
            try accessLog(err, ctx.log_level, mstr, path, status_code);
            return;
        };
        const cfg_dir = std.fs.path.dirname(ctx.config_path) orelse ".";
        const cfg_base = std.fs.path.basename(ctx.config_path);
        const tmp_name = try std.fmt.allocPrint(al, ".{s}.validate.{d}.tmp", .{ cfg_base, std.time.nanoTimestamp() });
        defer al.free(tmp_name);
        const tmp_path = try std.fs.path.join(al, &.{ cfg_dir, tmp_name });
        defer al.free(tmp_path);
        try std.fs.cwd().makePath(cfg_dir);
        try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = body_bytes });
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        var cfg = cuteclaw.config.loadApiConfigFromPath(al, tmp_path) catch {
            status_code = 400;
            try request.respond(
                \\{"error":"config validate failed (与 CLI `config validate` 一致)","code":1}
                \\
            , .{ .status = .bad_request, .extra_headers = jsonHeader() });
            try accessLog(err, ctx.log_level, mstr, path, status_code);
            return;
        };
        cfg.deinit(al);

        try cuteclaw.config.writeApiConfigAtomic(al, ctx.config_path, body_bytes);
        status_code = 200;
        try request.respond("{\"ok\":true}\n", .{ .extra_headers = jsonHeader() });
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/api/evolve")) {
        try postApiEvolve(al, ctx, &request, &status_code);
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/api/validate")) {
        try postApiValidate(al, &request, &status_code);
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/api/task")) {
        try postApiTask(al, ctx, &request, &status_code);
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/api/invoke")) {
        try postApiInvoke(al, ctx, &request, &status_code);
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/api/import-store")) {
        try postApiImportStore(al, ctx, &request, &status_code);
        try accessLog(err, ctx.log_level, mstr, path, status_code);
        return;
    }

    // --- 旧版路由 ---
    switch (method) {
        .GET => {
            if (std.mem.eql(u8, path, "/health")) {
                status_code = 200;
                try request.respond("{\"ok\":true}\n", .{ .extra_headers = jsonHeader() });
            } else if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/help")) {
                status_code = 200;
                try request.respond(
                    \\{"service":"cuteclaw","routes":["GET /health","GET /store","GET /status","POST /evolve","/api/*"]}
                    \\
                , .{ .extra_headers = jsonHeader() });
            } else if (std.mem.eql(u8, path, "/store")) {
                try getStoreCommon(al, ctx.store_path, &request, &status_code);
            } else if (std.mem.eql(u8, path, "/status")) {
                var rt = cuteclaw.ClawRuntime.init(al);
                var lk = try cuteclaw.store_lock.acquire(ctx.store_path, false);
                defer lk.deinit();
                cuteclaw.persist.loadFromPath(&rt, al, ctx.store_path) catch |e| switch (e) {
                    error.FileNotFound => {
                        status_code = 404;
                        try request.respond("{\"error\":\"store_not_found\"}\n", .{ .status = .not_found, .extra_headers = jsonHeader() });
                    },
                    else => return e,
                };
                const payload = try std.fmt.allocPrint(al,
                    \\{{"schema_version":{},"library_version":"{s}","episodic":{},"skills":{},"facts":{},"audit":{},"rollups":{},"tasks_recorded":{},"tasks_succeeded":{}}}
                    \\
                , .{
                    cuteclaw.persist.schema_version_v1,
                    cuteclaw.version,
                    rt.episodic.items.len,
                    rt.skills.items.len,
                    rt.facts.items.len,
                    rt.metrics.audit.items.len,
                    rt.metrics.rollupCount(),
                    rt.metrics.tasks_recorded,
                    rt.metrics.tasks_succeeded,
                });
                status_code = 200;
                try request.respond(payload, .{ .extra_headers = jsonHeader() });
            } else {
                status_code = 404;
                try request.respond("{\"error\":\"not_found\"}\n", .{ .status = .not_found, .extra_headers = jsonHeader() });
            }
        },
        .POST => {
            if (!std.mem.eql(u8, path, "/evolve")) {
                status_code = 404;
                try request.respond("{\"error\":\"not_found\"}\n", .{ .status = .not_found, .extra_headers = jsonHeader() });
            } else {
                try postEvolveLegacy(al, ctx.store_path, &request, &status_code);
            }
        },
        else => {
            status_code = 405;
            try request.respond("{\"error\":\"method_not_allowed\"}\n", .{ .status = .method_not_allowed, .extra_headers = jsonHeader() });
        },
    }
    try accessLog(err, ctx.log_level, mstr, path, status_code);
}

fn getStoreCommon(al: std.mem.Allocator, store_path: []const u8, request: *http.Server.Request, status_code: *u16) !void {
    var rt = cuteclaw.ClawRuntime.init(al);
    var lk = try cuteclaw.store_lock.acquire(store_path, false);
    defer lk.deinit();
    cuteclaw.persist.loadFromPath(&rt, al, store_path) catch |e| switch (e) {
        error.FileNotFound => {
            status_code.* = 404;
            try request.respond("{\"error\":\"store_not_found\"}\n", .{ .status = .not_found, .extra_headers = jsonHeader() });
            return;
        },
        else => return e,
    };
    const json = try cuteclaw.persist.snapshotToJsonAlloc(&rt, al, std.time.timestamp());
    status_code.* = 200;
    try request.respond(json, .{ .extra_headers = jsonHeader() });
}

fn postEvolveLegacy(al: std.mem.Allocator, store_path: []const u8, request: *http.Server.Request, status_code: *u16) !void {
    const body = readBody(al, request, max_body) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"content_length_required\"}\n", .{ .status = .length_required, .extra_headers = jsonHeader() });
        return;
    };
    var parsed = std.json.parseFromSlice(EvolveReq, al, body, .{ .ignore_unknown_fields = true }) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"invalid_json\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    defer parsed.deinit();
    try finishEvolve(al, store_path, parsed.value.proposal, parsed.value.policy, parsed.value.semver, request, status_code, true);
}

fn postApiEvolve(al: std.mem.Allocator, ctx: ServerCtx, request: *http.Server.Request, status_code: *u16) !void {
    const body = readBody(al, request, max_body) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"need proposal, policy, semver\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    var parsed = std.json.parseFromSlice(EvolveApiReq, al, body, .{ .ignore_unknown_fields = true }) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"invalid_json\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    defer parsed.deinit();
    try finishEvolve(al, ctx.store_path, parsed.value.proposal, parsed.value.policy, parsed.value.semver, request, status_code, false);
}

fn finishEvolve(
    al: std.mem.Allocator,
    store_path: []const u8,
    prop: ProposalPart,
    policy_s: []const u8,
    semver: []const u8,
    request: *http.Server.Request,
    status_code: *u16,
    legacy_json: bool,
) !void {
    const policy = cuteclaw.evolution.policyFromString(policy_s) orelse {
        status_code.* = 400;
        try request.respond("{\"error\":\"bad_policy\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    const p: cuteclaw.evolution.Proposal = .{
        .skill_name = prop.skill_name,
        .version_hint = prop.version_hint,
        .patch_summary = prop.patch_summary,
        .new_body = prop.new_body,
        .preconditions = prop.preconditions,
        .prohibitions = prop.prohibitions,
    };

    var lk = try cuteclaw.store_lock.acquire(store_path, true);
    defer lk.deinit();

    var rt = cuteclaw.ClawRuntime.init(al);
    cuteclaw.persist.loadFromPath(&rt, al, store_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    const ts = std.time.timestamp();
    const d = rt.applyProposal(p, policy, semver, ts) catch {
        status_code.* = 502;
        try request.respond("{\"error\":\"apply_proposal_error\"}\n", .{ .status = .internal_server_error, .extra_headers = jsonHeader() });
        return;
    };
    try cuteclaw.persist.saveToPath(&rt, al, store_path, ts);

    if (legacy_json) {
        const msg = switch (d) {
            .accepted => |s| try std.fmt.allocPrint(al, "{{\"ok\":true,\"decision\":\"accepted\",\"skill\":\"{s}\",\"version\":\"{s}\"}}\n", .{ s.name, s.version }),
            .rejected => try std.fmt.allocPrint(al, "{{\"ok\":false,\"decision\":\"rejected\"}}\n", .{}),
            .deferred => try std.fmt.allocPrint(al, "{{\"ok\":false,\"decision\":\"deferred\"}}\n", .{}),
        };
        status_code.* = 200;
        try request.respond(msg, .{ .extra_headers = jsonHeader() });
        return;
    }

    const stdout_line = try runtime_ops.allocEvolveStdout(al, d);
    defer al.free(stdout_line);
    const out_js = try std.json.Stringify.valueAlloc(al, stdout_line, .{});
    defer al.free(out_js);
    const body = try std.fmt.allocPrint(al, "{{\"ok\":true,\"stdout\":{s}}}\n", .{out_js});
    status_code.* = 200;
    try request.respond(body, .{ .extra_headers = jsonHeader() });
}

fn postApiValidate(al: std.mem.Allocator, request: *http.Server.Request, status_code: *u16) !void {
    const body = readBody(al, request, max_body) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"need proposal\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    var parsed = std.json.parseFromSlice(ValidateApiReq, al, body, .{ .ignore_unknown_fields = true }) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"invalid_json\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    defer parsed.deinit();
    const pr = parsed.value.proposal;
    const p: cuteclaw.evolution.Proposal = .{
        .skill_name = pr.skill_name,
        .version_hint = pr.version_hint,
        .patch_summary = pr.patch_summary,
        .new_body = pr.new_body,
        .preconditions = pr.preconditions,
        .prohibitions = pr.prohibitions,
    };
    var stdout_text: []const u8 = undefined;
    var ok: bool = undefined;
    var code: i32 = 0;
    cuteclaw.evolution.checkProposal(p) catch |e| {
        ok = false;
        code = 1;
        stdout_text = try std.fmt.allocPrint(al, "checkProposal: {s}\n", .{@errorName(e)});
        const out_js = try std.json.Stringify.valueAlloc(al, stdout_text, .{});
        const resp = try std.fmt.allocPrint(al,
            \\{{"ok":false,"code":{},"stdout":{s},"stderr":""}}
            \\
        , .{ code, out_js });
        status_code.* = 200;
        try request.respond(resp, .{ .extra_headers = jsonHeader() });
        return;
    };
    stdout_text = try std.fmt.allocPrint(al, "checkProposal: ok\n", .{});
    ok = true;
    code = 0;
    const out_js = try std.json.Stringify.valueAlloc(al, stdout_text, .{});
    const resp = try std.fmt.allocPrint(al,
        \\{{"ok":{},"code":{},"stdout":{s},"stderr":""}}
        \\
    , .{ ok, code, out_js });
    status_code.* = 200;
    try request.respond(resp, .{ .extra_headers = jsonHeader() });
}

fn postApiTask(al: std.mem.Allocator, ctx: ServerCtx, request: *http.Server.Request, status_code: *u16) !void {
    const body = readBody(al, request, max_body) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"need taskId, outcome, summary\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    var parsed = std.json.parseFromSlice(TaskApiReq, al, body, .{ .ignore_unknown_fields = true }) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"invalid_json\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    defer parsed.deinit();
    const oc = cuteclaw.memory.outcomeFromString(parsed.value.outcome) orelse {
        status_code.* = 400;
        try request.respond("{\"error\":\"bad outcome\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };

    var lk = try cuteclaw.store_lock.acquire(ctx.store_path, true);
    defer lk.deinit();
    var rt = cuteclaw.ClawRuntime.init(al);
    cuteclaw.persist.loadFromPath(&rt, al, ctx.store_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try rt.rememberEpisode(.{
        .task_id = parsed.value.taskId,
        .ended_unix = std.time.timestamp(),
        .summary = parsed.value.summary,
        .outcome = oc,
    });
    const ts = std.time.timestamp();
    try cuteclaw.persist.saveToPath(&rt, al, ctx.store_path, ts);
    const stdout_line = try std.fmt.allocPrint(al, "已追加情景并保存\n", .{});
    const out_js = try std.json.Stringify.valueAlloc(al, stdout_line, .{});
    const resp = try std.fmt.allocPrint(al, "{{\"ok\":true,\"stdout\":{s}}}\n", .{out_js});
    status_code.* = 200;
    try request.respond(resp, .{ .extra_headers = jsonHeader() });
}

fn postApiInvoke(al: std.mem.Allocator, ctx: ServerCtx, request: *http.Server.Request, status_code: *u16) !void {
    const body = readBody(al, request, max_body) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"need skill, ok (boolean)\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    var parsed = std.json.parseFromSlice(InvokeApiReq, al, body, .{ .ignore_unknown_fields = true }) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"invalid_json\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    defer parsed.deinit();

    var lk = try cuteclaw.store_lock.acquire(ctx.store_path, true);
    defer lk.deinit();
    var rt = cuteclaw.ClawRuntime.init(al);
    cuteclaw.persist.loadFromPath(&rt, al, ctx.store_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try rt.metrics.recordSkillInvocation(parsed.value.skill, parsed.value.ok, std.time.timestamp());
    try cuteclaw.persist.saveToPath(&rt, al, ctx.store_path, std.time.timestamp());
    const stdout_line = try std.fmt.allocPrint(al, "已记录技能调用: {s} success={}\n", .{ parsed.value.skill, parsed.value.ok });
    const out_js = try std.json.Stringify.valueAlloc(al, stdout_line, .{});
    const resp = try std.fmt.allocPrint(al, "{{\"ok\":true,\"stdout\":{s}}}\n", .{out_js});
    status_code.* = 200;
    try request.respond(resp, .{ .extra_headers = jsonHeader() });
}

fn postApiImportStore(al: std.mem.Allocator, ctx: ServerCtx, request: *http.Server.Request, status_code: *u16) !void {
    const body = readBody(al, request, max_body) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"expected JSON store document\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    var pj = std.json.parseFromSlice(cuteclaw.persist.StoreDocumentV1, al, body, .{ .ignore_unknown_fields = true }) catch {
        status_code.* = 400;
        try request.respond("{\"error\":\"invalid store json\"}\n", .{ .status = .bad_request, .extra_headers = jsonHeader() });
        return;
    };
    defer pj.deinit();

    var lk = try cuteclaw.store_lock.acquire(ctx.store_path, true);
    defer lk.deinit();
    var rt = cuteclaw.ClawRuntime.init(al);
    defer rt.deinit();
    cuteclaw.persist.applyLoadedDocument(&rt, pj.value) catch {
        status_code.* = 502;
        try request.respond("{\"error\":\"import apply failed\"}\n", .{ .status = .bad_gateway, .extra_headers = jsonHeader() });
        return;
    };
    try cuteclaw.persist.saveToPath(&rt, al, ctx.store_path, std.time.timestamp());
    const stdout_line = try std.fmt.allocPrint(al, "已自 stdin 导入并写入 {s}\n", .{ctx.store_path});
    const out_js = try std.json.Stringify.valueAlloc(al, stdout_line, .{});
    const resp = try std.fmt.allocPrint(al, "{{\"ok\":true,\"stdout\":{s}}}\n", .{out_js});
    status_code.* = 200;
    try request.respond(resp, .{ .extra_headers = jsonHeader() });
}
