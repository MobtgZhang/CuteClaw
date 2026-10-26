# CuteClaw Design

A **professional-domain** design agent: it only does **PCB** and **product enclosure / packaging (CAD)** work — it is not a general-purpose task agent.

The agent host is **100% Zig**: scheduling, LLM calls, tool execution, plugin management, memory, evolution and the sandbox all live in Zig with no third-party dependencies. The workbench is **Vue 3 + TypeScript** (`apps/web`).

Chinese version: [README_CN.md](README_CN.md).

## What it does

1. **Understands a design** — project state, design constraints, PCB nets and ratsnest, enclosure cavity.
2. **Executes the design** — it reads and validates real engineering files (KiCad, FreeCAD, STEP) instead of only giving advice.
3. **Evolves its design capability** — a Harness²-style `Propose → Probe → Compose → Evaluate → Promote` loop learns better strategies from engineering verification.

One rule is non-negotiable: evolution may rewrite strategies, skills and tool guidance, but it can **never** relax safety clearance, electrical rules or mechanical interference. Guardrails are excluded from the editable component set (`src/evolution/proposer.zig`).

## Highlights

- **Pure-Zig agent host** — agent loop, OpenAI-compatible / Anthropic-compatible LLM client (non-streaming and SSE), session message chain, tool registry with guardrail hooks, Cordis-style event bus, plugin kernel, capability-based sandbox.
- **Hard constraints first** — candidates that violate hard rules are eliminated before any optimization cost is compared. A shorter ratsnest never beats a DRC violation.
- **DeepSeek Harness (Cordis) plugin compatibility**, pinned to `manifestVersion 1`; plugin processes are controlled external tools and never hold scheduling authority.
- **Deterministic core library** — layered memory, explicit working set, gated skill evolution, metrics and audit, JSON snapshot persistence (schema v1).
- **Server** — REST + SSE + WebSocket (`GET /api/ws`, text frames are JSON-RPC), serving the Vue build as its static root.

## Requirements

- [Zig](https://ziglang.org/) **0.15.2+** (matches `minimum_zig_version` in `build.zig.zon`)
- Optional frontend toolchain: Node.js **20+** for `apps/web`
- Optional runtime for the DSH plugin bridge: Node.js (the bridge is an external tool process; the control plane stays in Zig)

## Quick start

```bash
zig build
zig build test
bash tests/cli_smoke.sh zig-out/bin/cuteclaw

# Conversation (single turn, or an interactive REPL without --message)
zig build run -- chat --message "Check the DRC on this board"

# Design plane: hard-constraint elimination, then cost ranking
zig build run -- design rank canonical \
  --constraints '[{"id":"drc","kind":"drc_errors","limit":0,"direction":"max","severity":"hard"},{"id":"rat","kind":"rat_length","limit":900,"direction":"max","severity":"soft"}]' \
  --file benchmarks/pcb/cases.json

# DRC on a real KiCad board
zig build run -- design drc canonical \
  --constraints '[{"id":"clearance","kind":"clearance","limit":0.3,"direction":"min","severity":"hard"}]' \
  --path benchmarks/pcb/canonical.kicad_pcb

# Plugins (DeepSeek Harness / Cordis compatible)
zig build run -- plugin load skills/design-review/package.json
zig build run -- plugin call design-review review --plugin skills/design-review/package.json \
  --args '{"candidates":[{"id":"A","measurements":{"drc_errors":0,"rat_length_mm":820}},{"id":"B","measurements":{"drc_errors":0,"rat_length_mm":670}},{"id":"C","measurements":{"drc_errors":3,"rat_length_mm":590}}],"limits":{"drc_errors":0}}'

# Serve the Vue workbench (127.0.0.1 only)
make app-build
zig build run -- serve --port 8788
```

One-shot verification of everything:

```bash
make check      # build + test + smoke + dsh + benchmark + drc + schemas
make live-chat  # one real conversation against the test API (default /data/api.json)
```

## Architecture

```text
Vue 3 + TypeScript (apps/web)
        |  REST / SSE / WebSocket (JSON-RPC frames)
        v
100% Zig Agent Host
  Agent loop | Plugin kernel | Design engine | Evolution engine
  Memory / Events | Security / Sandbox
        |
        +-- CAD / EDA bridge: KiCad, FreeCAD, STEP (controlled external tools)
        +-- DSH compatibility bridge: Cordis plugin bundle
        v
Versioned design artifacts
```

| Layer | Path | Responsibility |
|-------|------|----------------|
| Agent loop | `src/core/agent.zig` | LLM response → tool execution → result write-back until no tool calls or the round cap is hit |
| LLM client | `src/core/llm.zig` | `openai_compat` / `anthropic_compat`, non-streaming and SSE |
| Session | `src/core/session.zig` | Message chain and JSON serialization shared by HTTP / WebSocket / persistence; token cap comes from `max_tokens` in the LLM config |
| Tools | `src/core/tools.zig` | Tool registry with pre/post guardrail hooks and event dispatch |
| Events | `src/core/events.zig` | Cordis-style dispatch modes (`emit` / `waterfall` / `parallel` / `serial` / `bail`) + JSONL event log |
| Design engine | `src/design/` | Project state, constraints, geometry, PCB/ratsnest, DRC validation, tool surface |
| Adapters | `src/adapters/` | `.kicad_pcb` parsing, FreeCAD documents, STEP geometry |
| Plugins | `src/plugins/` | Cordis/DSH manifest, permissions, kernel, MCP, bridge invocation |
| Sandbox | `src/sandbox/policy.zig` | Capability set + workspace path boundary (out-of-root reads are refused) |
| Evolution | `src/evolution/` | Propose–Probe–Compose–Evaluate–Promote with gate, history and rollback |
| Core library | `src/memory.zig`, `src/working.zig`, `src/evolution.zig`, `src/metrics.zig`, `src/claw.zig`, `src/persist.zig`, `src/config.zig` | Deterministic memory/gate/metrics/persistence (no LLM, no network) |
| Server | `src/server/` | HTTP routes, JSON-RPC, WebSocket upgrade |
| CLI | `src/main.zig`, `src/cli_*.zig` | Command entry points |

## Design tools

The tool surface exposed to the model (`src/design/tools.zig`):

| Tool | Purpose |
|------|---------|
| `project_open` | Open or create a design project |
| `project_set_constraint` | Add or update one design constraint |
| `pcb_read` | Read a KiCad `.kicad_pcb` (`path` or `text`) into board outline, components and pads |
| `drc_check` | Run DRC against project constraints, return violations and pass/fail |
| `enclosure_fit` | Cavity-to-PCB fit clearance (negative value = interference) |
| `design_rank` | Eliminate hard violations first, then rank candidates by cost |
| `skill_list` | List available skills (working set + runtime memory) |

Constraint kinds cover `trace_width`, `clearance`, `hole_diameter`, `board_area`, `rat_length`, `iterations`, `enclosure_wall`, `fit_clearance`, `courtyard_gap`, `board_margin`, `drc_errors`, each with `min`/`max` direction and `hard`/`soft` severity.

Ratsnest length is computed as the minimum spanning tree per net.

## Evolution engine

Harness²'s editable components (`src/evolution/proposer.zig`): `system_prompt`, `guardrails`, `memory`, `tool_guidance`, `subagents`, `skills`, `scripts`, `plugins`. Only `guardrails` is locked.

Metrics used by the promotion gate (`src/evolution/evaluator.zig`):

| Metric | Measures |
|--------|----------|
| Engineering pass rate | Share of tasks satisfying hard engineering constraints |
| Design quality | Improvement relative to the baseline (>1 = better) |
| Tool reliability | CAD/EDA tool call success rate |
| Iterations to pass | Iterations needed to reach a passing design |
| Regression rate | Degradation of new skills on historical tasks |
| Human acceptance | Share of designs accepted by engineers |

Promotion (`src/evolution/promotion.zig`) reuses the core `MergePolicy` (`dry_run` / `require_human` / `auto_append_only`), records an audit entry per merge, and keeps a rollback reference. A fixed, unseen benchmark set (`benchmarks/pcb/`) is required to judge whether progress is real.

Example outcome from the canonical benchmark: `B` wins (cost 670), `C` is eliminated because it violates the hard DRC constraint even though its ratsnest is shorter.

## DeepSeek Harness (Cordis) plugin compatibility

Compatibility is pinned to **manifestVersion 1**. Two levels:

1. **Level 1 (pure Zig)** — `src/plugins/manifest.zig` parses the `dsh` field of `package.json` and `cordis.patch.yml`; unknown fields are ignored but the original text is preserved.
2. **Level 2 (bridge process)** — `bridges/deepseek-harness/bridge.mjs` loads a plugin bundle in a separate process, invoked by `src/plugins/dsh_bridge.zig`.

Bridge protocol:

```text
stdin  -> {"plugin":"<id>","tool":"<name>","args":{...}}
stdout -> {"jsonrpc":"2.0","ok":true,"content":"...","meta":{...}}
```

Environment variables: `PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT`, `CUTECLAW_PLUGIN_ID`, `CUTECLAW_TOOL`.

Errors are responses, not exit codes: the bridge writes a JSON-RPC error object to stdout and exits cleanly, so the Zig host can forward the code unchanged.

| Code | Meaning |
|------|---------|
| `-32700` | stdin parse error |
| `-32601` | tool not registered by the plugin |
| `-32602` | handler failure |
| `-32603` | internal error |

Capabilities are declared in the plugin manifest and mapped to the sandbox capability enum (`src/plugins/permissions.zig`, `src/sandbox/policy.zig`): `read_file`, `write_file`, `run_tool`, `network`, `plugin_exec`, `design_edit`, `evolve_write`. Names outside this set are ignored, and paths must stay inside the workspace root. Example plugins: `skills/design-review`, `skills/pcb-layout`, `skills/enclosure-design`.

## CLI

Global options (most subcommands): `--store PATH` (`CUTECLAW_STORE`, default `.cuteclaw/store.json`) and `--config PATH` (`CUTECLAW_CONFIG`, default `.cuteclaw/config.json`).

| Command | Purpose |
|---------|---------|
| `init` / `status` / `export` / `import` | Snapshot lifecycle |
| `demo` | Demo run that writes a default snapshot |
| `evolve --file F --policy P --semver V` | Authoritative proposal check + merge |
| `validate --file F` | Run `checkProposal` only |
| `task <id> <outcome> <summary...>` | Append an episodic record |
| `invoke <name> <ok\|fail>` | Record a skill invocation rollup |
| `working show` / `working set <field> <text...>` | Working set (`goal`, `constraints`, `confirmed_facts`, `next_step`) |
| `fact add <key> <value...>` | Append a semantic fact |
| `memory list\|get\|put\|rm` | Agent cache memory files (`--cache`, `--project`) |
| `agent-tool` | One JSON line in, one JSON line out; used by hosts for function calling |
| `config show` / `config init` / `config validate` | API configuration (never prints the key) |
| `chat [--message TEXT]` | Single-turn conversation, or interactive REPL; `--session`, `--json` |
| `plugin list\|load\|enable\|disable\|call` | DSH/Cordis compatible plugins |
| `design open\|constraint\|read\|drc\|fit\|rank\|skills` | Project, constraints, KiCad read, DRC, enclosure fit, ranking |
| `serve [--port N]` | HTTP + SSE + WebSocket on `127.0.0.1` only (default 8788 or `CUTECLAW_SERVE_PORT`) |
| `version` / `help` | Version and usage |

Exit codes: `0` success, `1` validation/business rejection, `2` usage, I/O or parse failure — see [docs/cli-exit-codes.md](docs/cli-exit-codes.md).

## HTTP and WebSocket API

| Endpoint | Notes |
|----------|-------|
| `GET /api/health` | Status, version, model, session/tool/plugin counts |
| `GET /api/sessions`, `/api/tools`, `/api/plugins`, `/api/metrics` | Read-only views |
| `POST /api/chat` | `{session, message}` → reply, rounds, tool calls, outcome |
| `POST /api/chat/stream` | SSE events: `session`, then `delta` / `reasoning` / `tool_call`, then `assistant` and `done` |
| `POST /api/drc` | Accepts the project object itself, or `{"project": {...}}` |
| `POST /api/kicad` | `{"text": "<kicad_pcb contents>"}` |
| `GET /api/ws` | WebSocket upgrade; text frames are handled as JSON-RPC |
| `GET /*` | Static files from `apps/web/dist`; `..` traversal is refused |

Legacy routes (`/health`, `/store`, `/status`, `POST /evolve`) remain for the older console.

After the WebSocket upgrade the socket is read and written directly (not through `std.Io` buffering), which is what makes long-lived connections, pipelined frames, ping/pong and close echo behave per RFC 6455.

## Frontend

`apps/web` (Vue 3 + TypeScript, Vite). Panels: `ChatPanel`, `ToolPanel`, `PluginPanel`, `ValidationPanel`, `MetricsPanel`.

```bash
cd apps/web
npm install        # make app-install
npm run build      # make app-build (vue-tsc --noEmit && vite build)
npm run dev        # make app-dev (Vite 5173, /api proxied to 8788)
```

`VITE_API_PORT` overrides the backend port (default `8788`). The legacy React console still lives in `web/`; the two are independent.

## Data contracts and benchmarks

- `schemas/design_task.json`, `schemas/tool_result.json`, `schemas/evolution_record.json` (validated by `make schemas`).
- `benchmarks/pcb/` — fixed task set plus KiCad samples (`cases.json`, `canonical.kicad_pcb`, `fit.kicad_pcb`).
- Snapshot format (schema v1) is documented in [docs/format.md](docs/format.md); `store.json` is written atomically and guarded by a `store.json.lock` advisory lock.

## Testing

```bash
make check
```

runs `zig build`, `zig build test` (94 test blocks in `src/`, plus the CLI entry point), and the shell suites:

| Script | Asserts |
|--------|---------|
| `tests/cli_smoke.sh` | Snapshot lifecycle, config validation, working set, facts, proposal gate, usage text flushed before exit |
| `tests/dsh_bridge.sh` | Plugin load + call, correct ranking, `-32601` for unknown tools |
| `tests/design_benchmark.sh` | Hard-constraint elimination before cost ranking; plugin result matches the benchmark |
| `tests/design_drc.sh` | Hard violations reported, clean board passes, positive fit clearance |
| `tests/schemas.sh` | Schema required/property counts |
| `tests/live_chat.sh` | Real conversation + tool loop against the test API; skips when unreachable |
| `tests/agent_web_fetch_search.sh` | Network + TLS smoke through `agent-tool` `web_fetch` (needs network) |

## Project layout

```text
src/            Zig core library + agent host
  core/         agent loop, llm, session, tools, events, jsonutil
  design/       project, constraints, geometry, pcb, validation, tools
  adapters/     kicad, freecad, step
  plugins/      manifest, permissions, registry, mcp, kernel, dsh_bridge
  sandbox/      capability + path policy
  evolution/    proposer, probe, composer, evaluator, promotion
  server/       http, rpc, websocket, serve
apps/web/       Vue 3 + TypeScript workbench
bridges/        DeepSeek Harness (Cordis) bridge process
skills/         example plugins
schemas/        JSON Schema contracts
benchmarks/     fixed benchmark task set
prompts/        agent system prompt templates
docs/           architecture, format, quickstart, plugin and frontend docs
tests/          shell test suites
web/            legacy React console
reports/        planning documents (plan-1, plan-2)
```

## Documentation

[docs/README.md](docs/README.md) is the index. Most useful starting points: [docs/architecture.md](docs/architecture.md), [docs/design-agent.md](docs/design-agent.md), [docs/dsh-plugins.md](docs/dsh-plugins.md), [docs/vue-app.md](docs/vue-app.md), [docs/quickstart.md](docs/quickstart.md), [docs/format.md](docs/format.md), [docs/roadmap.md](docs/roadmap.md).

Changes are tracked in [CHANGELOG.md](CHANGELOG.md); the version single source of truth is `src/version.zig`.

## License

[Apache License 2.0](LICENSE).
