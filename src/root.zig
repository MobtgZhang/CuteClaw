//! CuteClaw — 自进化 Agent 核心库（Zig）。
//!
//! 分层记忆、显式工作区、带门禁的进化流水线与 JSON 持久化；不含 LLM / 网络 / UI。

const std = @import("std");

pub const version = @import("version.zig").semantic;

pub const memory = @import("memory.zig");
pub const working = @import("working.zig");
pub const evolution = @import("evolution.zig");
pub const metrics = @import("metrics.zig");
pub const claw = @import("claw.zig");
pub const persist = @import("persist.zig");
pub const config = @import("config.zig");
pub const store_lock = @import("store_lock.zig");

pub const ClawRuntime = claw.ClawRuntime;

test "library version literal" {
    try std.testing.expect(std.mem.eql(u8, version, "0.1.1"));
}
