//! 进程级 I/O 上下文（Zig 0.17）。
//!
//! Zig 0.17 把文件系统、进程、时钟、网络都收进 `std.Io`：每个调用都要显式拿到一个
//! `Io` 实例。这里集中持有唯一一个进程级 `Io`，并保留旧的调用形状（以 cwd 为基准的
//! 相对路径、无需显式 io 参数的文件操作），让上层代码不必把 io 参数一路传下去。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// 解析符号链接的最大跳数，超过即按环路处理。
const max_symlink_hops: usize = 32;

var threaded: ?Io.Threaded = null;
var environ: std.process.Environ = .empty;

/// 由入口在拿到 `process.Init` 之后调用：环境变量与 Io 实现都来自 init。
pub fn setup(init: std.process.Init.Minimal) void {
    environ = init.environ;
    threaded = Io.Threaded.init(std.heap.page_allocator, .{ .environ = init.environ });
}

/// 进程级 Io；未显式 setup 时按当前环境变量惰性初始化。
pub fn io() Io {
    if (threaded == null) {
        threaded = Io.Threaded.init(std.heap.page_allocator, .{ .environ = environ });
    }
    return threaded.?.io();
}

pub const path = std.fs.path;
pub const max_path_bytes = Io.Dir.max_path_bytes;

pub const File = struct {
    handle: Io.File,

    pub const Lock = Io.File.Lock;
    pub const Kind = Io.File.Kind;
    pub const Stat = Io.File.Stat;

    pub fn wrap(handle: Io.File) File {
        return .{ .handle = handle };
    }

    pub fn stdin() File {
        return wrap(Io.File.stdin());
    }

    pub fn stdout() File {
        return wrap(Io.File.stdout());
    }

    pub fn stderr() File {
        return wrap(Io.File.stderr());
    }

    pub fn close(self: File) void {
        Io.File.close(self.handle, io());
    }

    pub fn reader(self: File, buffer: []u8) Io.File.Reader {
        return Io.File.reader(self.handle, io(), buffer);
    }

    pub fn writer(self: File, buffer: []u8) Io.File.Writer {
        return Io.File.writer(self.handle, io(), buffer);
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        return Io.File.writeStreamingAll(self.handle, io(), bytes);
    }

    pub fn write(self: File, bytes: []const u8) !usize {
        return Io.File.writeStreaming(self.handle, io(), "", &.{bytes}, 1);
    }

    pub fn read(self: File, buffer: []u8) !usize {
        return Io.File.readStreaming(self.handle, io(), &.{buffer});
    }

    pub fn stat(self: File) !Stat {
        return Io.File.stat(self.handle, io());
    }

    pub fn readToEndAlloc(self: File, gpa: Allocator, limit: usize) ![]u8 {
        var buffer: [8192]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        var fr = self.reader(&buffer);
        const r = &fr.interface;
        errdefer out.deinit(
            gpa,
        );
        while (true) {
            const want = limit - out.items.len;
            if (want == 0) return error.StreamTooLong;
            const n = r.readSliceShort(buffer[0..@min(want, buffer.len)]) catch break;
            if (n == 0) break;
            try out.appendSlice(gpa, buffer[0..n]);
        }
        return out.toOwnedSlice(
            gpa,
        );
    }

    /// 追加写入：以当前文件大小作为写入偏移，等价于旧 `seekFromEnd(0)`。
    pub fn appendAll(self: File, bytes: []const u8) !void {
        const st = try self.stat();
        return Io.File.writePositionalAll(self.handle, io(), bytes, st.size);
    }
};

pub const Dir = struct {
    handle: Io.Dir,

    pub fn wrap(handle: Io.Dir) Dir {
        return .{ .handle = handle };
    }

    pub fn cwd() Dir {
        return wrap(Io.Dir.cwd());
    }

    pub fn close(self: Dir) void {
        Io.Dir.close(self.handle, io());
    }

    pub fn openFile(self: Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) !File {
        return File.wrap(try Io.Dir.openFile(self.handle, io(), sub_path, options));
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) !Dir {
        return wrap(try Io.Dir.openDir(self.handle, io(), sub_path, options));
    }

    pub fn createFile(self: Dir, sub_path: []const u8, flags: Io.Dir.CreateFileOptions) !File {
        return File.wrap(try Io.Dir.createFile(self.handle, io(), sub_path, flags));
    }

    pub fn writeFile(self: Dir, options: Io.Dir.WriteFileOptions) !void {
        return Io.Dir.writeFile(self.handle, io(), options);
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        return Io.Dir.deleteFile(self.handle, io(), sub_path);
    }

    pub fn deleteDir(self: Dir, sub_path: []const u8) !void {
        return Io.Dir.deleteDir(self.handle, io(), sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) !void {
        return Io.Dir.deleteTree(self.handle, io(), sub_path);
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        return Io.Dir.createDirPath(self.handle, io(), sub_path);
    }

    pub fn makeDir(self: Dir, sub_path: []const u8) !void {
        return Io.Dir.createDir(self.handle, io(), sub_path, Io.File.Permissions.default_dir);
    }

    pub fn access(self: Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) !void {
        return Io.Dir.access(self.handle, io(), sub_path, options);
    }

    pub fn stat(self: Dir, sub_path: []const u8) !File.Stat {
        return Io.Dir.statFile(self.handle, io(), sub_path, .{});
    }

    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) !void {
        return Io.Dir.rename(self.handle, old_sub_path, self.handle, new_sub_path, io());
    }

    pub fn readFileAlloc(self: Dir, gpa: Allocator, sub_path: []const u8, limit: usize) ![]u8 {
        return Io.Dir.readFileAlloc(self.handle, io(), sub_path, gpa, Io.Limit.limited(limit));
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .it = Io.Dir.iterate(self.handle) };
    }

    /// 解析成绝对路径，并跟随符号链接；无法跟随时退化为字面解析结果。
    pub fn realpathAlloc(self: Dir, gpa: Allocator, sub_path: []const u8) ![]u8 {
        if (!path.isAbsolute(sub_path)) {
            const base = try path.resolveAlloc(gpa, &.{sub_path});
            errdefer gpa.free(base);
            var buffer: [max_path_bytes]u8 = undefined;
            const n = Io.Dir.realPathFile(self.handle, io(), base, &buffer) catch {
                return base;
            };
            gpa.free(base);
            return gpa.dupe(u8, buffer[0..n]);
        }
        var buffer: [max_path_bytes]u8 = undefined;
        const n = Io.Dir.realPathFile(self.handle, io(), sub_path, &buffer) catch return gpa.dupe(u8, sub_path);
        return gpa.dupe(u8, buffer[0..n]);
    }
};

pub const Iterator = struct {
    it: Io.Dir.Iterator,

    pub fn next(self: *Iterator) Io.Dir.Iterator.Error!?Io.Dir.Entry {
        return Io.Dir.Iterator.next(&self.it, io());
    }
};

pub fn openFileAbsolute(absolute_path: []const u8, options: Io.Dir.OpenFileOptions) !File {
    return File.wrap(try Io.Dir.openFileAbsolute(io(), absolute_path, options));
}

pub fn createFileAbsolute(absolute_path: []const u8, flags: Io.Dir.CreateFileOptions) !File {
    return File.wrap(try Io.Dir.createFileAbsolute(io(), absolute_path, flags));
}

pub fn openDirAbsolute(absolute_path: []const u8, options: Io.Dir.OpenOptions) !Dir {
    return Dir.wrap(try Io.Dir.openDirAbsolute(io(), absolute_path, options));
}

pub fn deleteFileAbsolute(absolute_path: []const u8) !void {
    return Io.Dir.deleteFileAbsolute(io(), absolute_path);
}

pub fn makeDirAbsolute(absolute_path: []const u8) !void {
    return Io.Dir.createDirAbsolute(io(), absolute_path, Io.File.Permissions.default_dir);
}

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn nowSec() i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io(), .real).nanoseconds, std.time.ns_per_s));
}

pub fn nowMs() i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io(), .real).nanoseconds, std.time.ns_per_ms));
}

pub fn nowNs() i64 {
    return @intCast(Io.Timestamp.now(io(), .real).nanoseconds);
}

/// 环境变量取值（调用方持有所有权）。缺失时返回 `EnvironmentVariableNotFound`，
/// 与旧 `std.process.getEnvVarOwned` 的调用形状保持一致。
pub fn envOwned(gpa: Allocator, key: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory, InvalidWtf8 }![]u8 {
    return environ.getAlloc(gpa, key) catch |e| switch (e) {
        error.EnvironmentVariableMissing => return error.EnvironmentVariableNotFound,
        else => |err| return err,
    };
}

/// 进程环境变量表（由入口的 `process.Init` 提供）。
pub fn envTable() std.process.Environ {
    return environ;
}

pub fn env(key: []const u8) ?[]const u8 {
    return environ.getPosix(key);
}

test "ioctx 使用当前目录作为基准" {
    const gpa = std.testing.allocator;
    const root = try cwd().realpathAlloc(gpa, ".");
    defer gpa.free(root);
    try std.testing.expect(path.isAbsolute(root));
    try std.testing.expect(nowSec() > 0);
}

test "ioctx 文件读写往返" {
    const gpa = std.testing.allocator;
    const name = try std.fmt.allocPrint(gpa, "ioctx-test-{d}.txt", .{nowNs()});
    defer gpa.free(name);

    const file = try cwd().createFile(name, .{ .truncate = true });
    try file.writeAll("hello");
    file.close();

    const raw = try cwd().readFileAlloc(gpa, name, 1024);
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("hello", raw);

    try cwd().deleteFile(name);
}
