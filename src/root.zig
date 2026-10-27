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

pub const jsonutil = @import("core/jsonutil.zig");
pub const events = @import("core/events.zig");
pub const tools = @import("core/tools.zig");
pub const session = @import("core/session.zig");
pub const agent = @import("core/agent.zig");
pub const llm = @import("core/llm.zig");
pub const sandbox = @import("sandbox/policy.zig");
pub const plugins_manifest = @import("plugins/manifest.zig");
pub const plugins_permissions = @import("plugins/permissions.zig");
pub const plugins_registry = @import("plugins/registry.zig");
pub const plugins_mcp = @import("plugins/mcp.zig");
pub const plugins_dsh = @import("plugins/dsh_bridge.zig");
pub const plugins_kernel = @import("plugins/kernel.zig");

pub const design_geometry = @import("design/geometry.zig");
pub const design_constraints = @import("design/constraints.zig");
pub const design_pcb = @import("design/pcb.zig");
pub const design_validation = @import("design/validation.zig");
pub const design_project = @import("design/project.zig");
pub const design_tools = @import("design/tools.zig");
pub const graph_graph = @import("graph/graph.zig");
pub const graph_state = @import("graph/state.zig");
pub const graph_gates = @import("graph/gates.zig");
pub const graph_executor = @import("graph/executor.zig");
pub const graph_skills = @import("graph/skills.zig");
pub const graph_tools = @import("graph/tools.zig");
pub const loop_agent = @import("loop/agent_loop.zig");
pub const loop_hooks = @import("loop/hooks.zig");
pub const loop_approval = @import("loop/approval.zig");
pub const loop_compaction = @import("loop/compaction.zig");
pub const loop_checkpoint = @import("loop/checkpoint.zig");
pub const loop_planning = @import("loop/planning.zig");
pub const loop_learning = @import("loop/learning.zig");
pub const loop_skillfile = @import("loop/skillfile.zig");
pub const loop_subagent = @import("loop/subagent.zig");
pub const loop_tools = @import("loop/tools.zig");
pub const adapters_kicad = @import("adapters/kicad.zig");
pub const adapters_freecad = @import("adapters/freecad.zig");
pub const adapters_step = @import("adapters/step.zig");
pub const evolution_proposer = @import("evolution/proposer.zig");
pub const evolution_probe = @import("evolution/probe.zig");
pub const evolution_evaluator = @import("evolution/evaluator.zig");
pub const evolution_composer = @import("evolution/composer.zig");
pub const evolution_promotion = @import("evolution/promotion.zig");
pub const server_websocket = @import("server/websocket.zig");
pub const server_http = @import("server/http.zig");
pub const server_rpc = @import("server/rpc.zig");
pub const server_serve = @import("server/serve.zig");
pub const host = @import("host.zig");
pub const cli_chat = @import("cli_chat.zig");
pub const cli_plugin = @import("cli_plugin.zig");
pub const cli_design = @import("cli_design.zig");
pub const cli_graph = @import("cli_graph.zig");
pub const cli_loop = @import("cli_loop.zig");
pub const cli_common = @import("cli_common.zig");

test "library version literal" {
    try std.testing.expect(std.mem.eql(u8, version, "0.1.1"));
}

test "force fromJson analysis" {
    const gpa = std.testing.allocator;
    var p = try design_project.DesignProject.fromJson(gpa, "{\"id\":\"x\",\"name\":\"y\",\"requirements\":{\"a\":\"b\"}}");
    defer p.deinit();
}
