//! 原子工具执行：供 Agent 宿主通过子进程 JSON 调用（路径限制在项目 cache 下）。
//! 工具名与 prompts/agent-tools.openai.json 保持一致。
const std = @import("std");
const Allocator = std.mem.Allocator;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isSafeRel(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    return true;
}

fn osTag() []const u8 {
    switch (@import("builtin").os.tag) {
        .linux => return "linux",
        .macos => return "macos",
        .windows => return "windows",
        else => return "other",
    }
}

fn projectBase(gpa: std.mem.Allocator, cache_root: []const u8, project: []const u8) ![]const u8 {
    return try std.fs.path.join(gpa, &.{ cache_root, "projects", project });
}

fn bucketRoot(
    gpa: std.mem.Allocator,
    base: []const u8,
    skills_sub: []const u8,
    memory_sub: []const u8,
    bucket: []const u8,
) ![]const u8 {
    const sub = if (eql(bucket, "skills"))
        skills_sub
    else if (eql(bucket, "memory"))
        memory_sub
    else
        return error.InvalidBucket;
    return try std.fs.path.join(gpa, &.{ base, sub });
}

fn resolveUnderRoot(gpa: Allocator, abs_root: []const u8, rel: []const u8) ![]u8 {
    if (!isSafeRel(rel)) return error.BadRel;
    const canon_root = try std.fs.path.resolve(gpa, &.{abs_root});
    defer gpa.free(canon_root);
    const full = try std.fs.path.resolve(gpa, &.{ canon_root, rel });
    defer gpa.free(full);
    if (full.len < canon_root.len) return error.PathEscape;
    if (!std.mem.eql(u8, full[0..canon_root.len], canon_root)) return error.PathEscape;
    if (full.len > canon_root.len) {
        const next = full[canon_root.len];
        if (next != std.fs.path.sep and next != '/') return error.PathEscape;
    }
    return try gpa.dupe(u8, full);
}

fn ensureParentDirsForFile(abs_file: []const u8) !void {
    const d = std.fs.path.dirname(abs_file) orelse return;
    if (d.len == 0) return;
    if (std.mem.eql(u8, d, "/")) return;
    if (builtinIsWindows() and d.len == 3 and d[1] == ':' and (d[2] == '\\' or d[2] == '/')) return;
    try ensureParentDirsForFile(d);
    std.fs.makeDirAbsolute(d) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |x| return x,
    };
}

fn builtinIsWindows() bool {
    return @import("builtin").os.tag == .windows;
}

fn readStdinAll(gpa: std.mem.Allocator, limit: usize) ![]u8 {
    const stdin = std.fs.File.stdin();
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) break;
        if (list.items.len + n > limit) return error.InputTooLarge;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return try list.toOwnedSlice(gpa);
}

fn writeJsonOk(out: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, out);
    try out.writeAll("\n");
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    switch (v) {
        .string => |s| return s,
        else => return null,
    }
}

fn numFieldU32(obj: std.json.ObjectMap, key: []const u8, default: u32) u32 {
    const v = obj.get(key) orelse return default;
    switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) return @intCast(i) else return default,
        .float => |f| if (f >= 0 and f <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return @intFromFloat(f) else return default,
        else => return default,
    }
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    switch (v) {
        .bool => |b| return b,
        else => return default,
    }
}

fn ensureDirChain(abs: []const u8) !void {
    if (abs.len == 0) return error.BadPath;
    if (std.mem.eql(u8, abs, "/")) return;
    if (builtinIsWindows() and abs.len == 3 and abs[1] == ':' and (abs[2] == '\\' or abs[2] == '/')) return;
    const parent = std.fs.path.dirname(abs) orelse return;
    if (parent.len > 0) try ensureDirChain(parent);
    std.fs.makeDirAbsolute(abs) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |x| return x,
    };
}

fn lineContainsNeedle(hay: []const u8, needle: []const u8, ascii_ic: bool) bool {
    if (needle.len == 0) return false;
    if (!ascii_ic) return std.mem.indexOf(u8, hay, needle) != null;
    var h_i: usize = 0;
    while (h_i + needle.len <= hay.len) : (h_i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(hay[h_i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn isBlockedUrlHost(host: []const u8) bool {
    if (host.len == 0) return true;
    if (eql(host, "localhost")) return true;
    if (std.mem.startsWith(u8, host, "127.")) return true;
    if (std.mem.startsWith(u8, host, "10.")) return true;
    if (std.mem.startsWith(u8, host, "192.168.")) return true;
    if (std.mem.startsWith(u8, host, "172.")) return true;
    if (eql(host, "0.0.0.0")) return true;
    if (eql(host, "::1")) return true;
    return false;
}

/// 与常见浏览器接近的 UA / Accept，减少搜索引擎与 CDN 对「无头客户端」的拒绝或空响应（仍受站点策略影响）。
const web_fetch_user_agent = "Mozilla/5.0 (compatible; CuteClawAgent/0.1; +https://github.com/mobtgzhang/CuteClaw) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 读取正文至多 `max_bytes` 字节；超出部分丢弃（`allocRemaining(.limited)` 在正文更大时会报 StreamTooLong）。
fn readHttpBodyCapped(gpa: std.mem.Allocator, r: *std.Io.Reader, max_bytes: u32) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    const cap: usize = max_bytes;
    while (total < cap) {
        const want = @min(buf.len, cap - total);
        const n = try r.readSliceShort(buf[0..want]);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
        total += n;
    }
    _ = r.discardRemaining() catch {};
    return try list.toOwnedSlice(gpa);
}

fn webFetch(gpa: std.mem.Allocator, url_str: []const u8, max_bytes: u32) ![]u8 {
    if (std.mem.startsWith(u8, url_str, "file:")) return error.BlockedScheme;
    const uri = try std.Uri.parse(url_str);
    const host = switch (uri.host orelse return error.BadUrl) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    if (isBlockedUrlHost(host)) return error.BlockedHost;

    var client: std.http.Client = .{
        .allocator = gpa,
        .read_buffer_size = 65536,
        .write_buffer_size = 4096,
    };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(8),
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = web_fetch_user_agent },
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" },
            .{ .name = "Accept-Language", .value = "zh-CN,zh;q=0.9,en;q=0.8" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [65536]u8 = undefined;
    var response = try req.receiveHead(redirect_buf[0..]);
    if (response.head.status != .ok) return error.HttpStatus;

    var transfer_buf: [8192]u8 = undefined;
    const r = response.reader(&transfer_buf);
    return try readHttpBodyCapped(gpa, r, max_bytes);
}

fn shellAllowed() bool {
    const v = std.posix.getenv("CUTECLAW_AGENT_SHELL") orelse return false;
    return eql(v, "1");
}

const KillerCtx = struct {
    child: *std.process.Child,
    done: *std.atomic.Value(bool),

    fn run(self: *@This(), timeout_ms: u32) void {
        const step_ms: u32 = 100;
        var left = timeout_ms;
        while (left > 0) {
            const slice = @min(step_ms, left);
            std.Thread.sleep(@as(u64, slice) * std.time.ns_per_ms);
            left -= slice;
            if (self.done.load(.seq_cst)) return;
        }
        _ = self.child.kill() catch {};
    }
};

fn shellExec(gpa: std.mem.Allocator, cwd_abs: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    if (!shellAllowed()) return error.ShellDisabled;

    const argv_shell = switch (@import("builtin").os.tag) {
        .windows => &[_][]const u8{ "cmd", "/C", command },
        else => &[_][]const u8{ "/bin/sh", "-c", command },
    };

    var child = std.process.Child.init(argv_shell, gpa);
    child.cwd = cwd_abs;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(gpa);

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var done_flag = std.atomic.Value(bool).init(false);
    var kctx = KillerCtx{ .child = &child, .done = &done_flag };
    const killer = try std.Thread.spawn(.{}, KillerCtx.run, .{ &kctx, timeout_ms });
    defer {
        done_flag.store(true, .seq_cst);
        killer.join();
    }

    const max_out: usize = 256 * 1024;
    try child.collectOutput(gpa, &stdout, &stderr, max_out);
    done_flag.store(true, .seq_cst);

    const term = try child.wait();
    switch (term) {
        .Exited => |c| {
            if (c != 0) {
                return try std.fmt.allocPrint(gpa, "[exit {d}]\n{s}\n{s}", .{ c, stdout.items, stderr.items });
            }
        },
        else => return error.ProcessFailed,
    }
    if (stderr.items.len > 0) {
        return try std.fmt.allocPrint(gpa, "{s}\n--- stderr ---\n{s}", .{ stdout.items, stderr.items });
    }
    return try gpa.dupe(u8, stdout.items);
}

pub fn cmdAgentTool(gpa: std.mem.Allocator, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    const raw = readStdinAll(gpa, 1024 * 1024) catch |e| {
        try err.print("读取 stdin 失败: {}\n", .{e});
        std.process.exit(2);
        return;
    };
    defer gpa.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch |e| {
        try err.print("JSON 解析失败: {}\n", .{e});
        std.process.exit(2);
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try err.writeAll("根须为 JSON 对象\n");
            std.process.exit(2);
            return;
        },
    };

    const tool = strField(root, "tool") orelse {
        try err.writeAll("缺少 tool\n");
        std.process.exit(2);
        return;
    };
    const cache_root = strField(root, "cache_root") orelse {
        try err.writeAll("缺少 cache_root\n");
        std.process.exit(2);
        return;
    };
    const project = strField(root, "project") orelse "default";
    const skills_sub = strField(root, "skills_subdir") orelse "skills";
    const memory_sub = strField(root, "memory_subdir") orelse "memory";

    if (eql(tool, "env_info")) {
        try writeJsonOk(out, .{
            .ok = true,
            .result = .{
                .os = osTag(),
                .arch = @tagName(@import("builtin").cpu.arch),
            },
        });
        return;
    }

    const args_val = root.get("args") orelse {
        try writeJsonOk(out, .{ .ok = false, .err = "missing args" });
        return;
    };
    const argo = switch (args_val) {
        .object => |o| o,
        else => {
            try writeJsonOk(out, .{ .ok = false, .err = "args must be object" });
            return;
        },
    };

    const base = projectBase(gpa, cache_root, project) catch |e| {
        try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
        return;
    };
    defer gpa.free(base);

    const ensure_touch = try std.fs.path.join(gpa, &.{ base, ".cuteclaw_agent_dir" });
    defer gpa.free(ensure_touch);
    ensureParentDirsForFile(ensure_touch) catch |e| {
        try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
        return;
    };

    if (eql(tool, "file_read")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing rel" });
            return;
        };
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        const abs = resolveUnderRoot(gpa, broot, rel) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        };
        defer gpa.free(abs);
        const f = std.fs.openFileAbsolute(abs, .{}) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer f.close();
        const content = f.readToEndAlloc(gpa, 512 * 1024) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer gpa.free(content);
        try writeJsonOk(out, .{ .ok = true, .result = .{ .content = content } });
        return;
    }

    if (eql(tool, "file_write")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing rel" });
            return;
        };
        const content = strField(argo, "content") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing content" });
            return;
        };
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        const abs = resolveUnderRoot(gpa, broot, rel) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        };
        defer gpa.free(abs);
        try ensureParentDirsForFile(abs);
        const wf = try std.fs.createFileAbsolute(abs, .{ .truncate = true });
        defer wf.close();
        try wf.writeAll(content);
        try writeJsonOk(out, .{ .ok = true, .result = .{ .written = true, .path = abs } });
        return;
    }

    if (eql(tool, "file_list")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse "";
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        var list_dir: std.fs.Dir = if (rel.len == 0)
            try std.fs.openDirAbsolute(broot, .{ .iterate = true })
        else blk: {
            const abs = resolveUnderRoot(gpa, broot, rel) catch {
                try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
                return;
            };
            defer gpa.free(abs);
            break :blk try std.fs.openDirAbsolute(abs, .{ .iterate = true });
        };
        defer list_dir.close();

        var paths = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (paths.items) |p| gpa.free(p);
            paths.deinit(gpa);
        }
        var it = list_dir.iterate();
        while (try it.next()) |ent| {
            const line = try std.fmt.allocPrint(gpa, "{s}", .{ent.name});
            try paths.append(gpa, line);
        }
        try writeJsonOk(out, .{ .ok = true, .result = .{ .entries = paths.items } });
        return;
    }

    if (eql(tool, "file_stat")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing rel" });
            return;
        };
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        const abs = resolveUnderRoot(gpa, broot, rel) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        };
        defer gpa.free(abs);
        const f = std.fs.openFileAbsolute(abs, .{}) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer f.close();
        const st = f.stat() catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        const kind_s: []const u8 = switch (st.kind) {
            .file => "file",
            .directory => "directory",
            else => "other",
        };
        try writeJsonOk(out, .{
            .ok = true,
            .result = .{
                .kind = kind_s,
                .size = st.size,
            },
        });
        return;
    }

    if (eql(tool, "file_mkdir")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing rel" });
            return;
        };
        if (!isSafeRel(rel)) {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        }
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        const abs = resolveUnderRoot(gpa, broot, rel) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        };
        defer gpa.free(abs);
        ensureDirChain(abs) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        try writeJsonOk(out, .{ .ok = true, .result = .{ .created = true } });
        return;
    }

    if (eql(tool, "file_remove")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing rel" });
            return;
        };
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        const abs = resolveUnderRoot(gpa, broot, rel) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        };
        defer gpa.free(abs);
        {
            const f = std.fs.openFileAbsolute(abs, .{}) catch |e| {
                try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
                return;
            };
            defer f.close();
            const st = f.stat() catch |e| {
                try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
                return;
            };
            if (st.kind != .file) {
                try writeJsonOk(out, .{ .ok = false, .err = "not_a_file" });
                return;
            }
        }
        std.fs.deleteFileAbsolute(abs) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        try writeJsonOk(out, .{ .ok = true, .result = .{ .removed = true } });
        return;
    }

    if (eql(tool, "text_search")) {
        const bucket = strField(argo, "bucket") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing bucket" });
            return;
        };
        const rel = strField(argo, "rel") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing rel" });
            return;
        };
        const needle = strField(argo, "needle") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing needle" });
            return;
        };
        if (needle.len == 0) {
            try writeJsonOk(out, .{ .ok = false, .err = "empty needle" });
            return;
        }
        const max_m = numFieldU32(argo, "max_matches", 80);
        const ic = boolField(argo, "case_insensitive", false);
        const broot = bucketRoot(gpa, base, skills_sub, memory_sub, bucket) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "invalid bucket" });
            return;
        };
        defer gpa.free(broot);
        const abs = resolveUnderRoot(gpa, broot, rel) catch {
            try writeJsonOk(out, .{ .ok = false, .err = "bad path" });
            return;
        };
        defer gpa.free(abs);
        const f = std.fs.openFileAbsolute(abs, .{}) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer f.close();
        const st = f.stat() catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        if (st.kind != .file) {
            try writeJsonOk(out, .{ .ok = false, .err = "not_a_file" });
            return;
        }
        const content = f.readToEndAlloc(gpa, 512 * 1024) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer gpa.free(content);

        const Match = struct { line: u32, text: []const u8 };
        var matches: std.ArrayListUnmanaged(Match) = .empty;
        defer {
            for (matches.items) |m| gpa.free(m.text);
            matches.deinit(gpa);
        }

        var line_no: u32 = 1;
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (lineContainsNeedle(line, needle, ic)) {
                const dup = try gpa.dupe(u8, line);
                try matches.append(gpa, .{ .line = line_no, .text = dup });
                if (matches.items.len >= max_m) break;
            }
            line_no +%= 1;
        }

        try writeJsonOk(out, .{ .ok = true, .result = .{ .matches = matches.items } });
        return;
    }

    if (eql(tool, "web_fetch")) {
        const url_s = strField(argo, "url") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing url" });
            return;
        };
        const max_b = numFieldU32(argo, "max_bytes", 512 * 1024);
        const body = webFetch(gpa, url_s, max_b) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer gpa.free(body);
        try writeJsonOk(out, .{ .ok = true, .result = .{ .body = body } });
        return;
    }

    if (eql(tool, "shell_exec")) {
        const command = strField(argo, "command") orelse {
            try writeJsonOk(out, .{ .ok = false, .err = "missing command" });
            return;
        };
        const timeout_ms = numFieldU32(argo, "timeout_ms", 60_000);
        const out_s = shellExec(gpa, base, command, timeout_ms) catch |e| {
            try writeJsonOk(out, .{ .ok = false, .err = @errorName(e) });
            return;
        };
        defer gpa.free(out_s);
        try writeJsonOk(out, .{ .ok = true, .result = .{ .output = out_s } });
        return;
    }

    try writeJsonOk(out, .{ .ok = false, .err = "unknown tool" });
}
