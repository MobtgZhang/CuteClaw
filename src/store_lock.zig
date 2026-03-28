//! 对 `store.json` 旁路 `basename.lock` 做咨询锁，协调 CLI / 多进程写入（Linux 等为 flock）。
//! 不支持锁的平台退化为无锁（与旧行为一致）。

const std = @import("std");

pub const Held = struct {
    file: ?std.fs.File = null,

    pub fn deinit(self: *Held) void {
        if (self.file) |f| f.close();
        self.* = .{};
    }
};

pub fn acquire(store_path: []const u8, exclusive: bool) !Held {
    const dirname = std.fs.path.dirname(store_path) orelse ".";
    const base = std.fs.path.basename(store_path);

    // 数据目录可能尚未存在（未执行 init）；先创建再 open，避免 FileNotFound 导致 HTTP 无响应。
    try std.fs.cwd().makePath(dirname);
    var dir = try std.fs.cwd().openDir(dirname, .{});
    defer dir.close();

    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_name = try std.fmt.bufPrint(&lock_buf, "{s}.lock", .{base});

    const lock_kind: std.fs.File.Lock = if (exclusive) .exclusive else .shared;
    const f = dir.createFile(lock_name, .{
        .read = true,
        .truncate = false,
        .lock = lock_kind,
    }) catch |err| switch (err) {
        error.FileLocksNotSupported => return .{},
        else => |e| return e,
    };
    return .{ .file = f };
}
