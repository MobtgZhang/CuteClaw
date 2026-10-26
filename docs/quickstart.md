# Quickstart

## 环境

```bash
zig version   # 建议 0.15.2
```

## 构建与测试

```bash
zig build
zig build test
zig build fmt # 可选：检查格式（CI 同款）
zig install   # 可选：安装到 zig-out/bin/cuteclaw
bash tests/cli_smoke.sh zig-out/bin/cuteclaw  # 可选：冒烟
```

## CLI 一览

| 命令 | 作用 |
|------|------|
| `help` / `version` | 帮助与版本 |
| `init [--force]` | 创建空快照（默认 `.cuteclaw/store.json`） |
| `demo` | 加载已有快照（若存在）、追加情景、必要时合并演示技能并保存 |
| `status` | 打印快照统计与工作区摘要 |
| `export` | 将当前快照以 JSON 打印到 stdout |
| `import` | 从 **stdin** 读入 JSON 并写入 `--store` |
| `evolve --file F --policy P --semver V` | 读取提议、合并、保存（`semver` 在 `auto_append_only` 下须通过宽松校验） |
| `validate --file F` | 仅运行 `checkProposal` |
| `task <id> <outcome> <summary...>` | 追加情景记录（`outcome`: success/failed/aborted/needs_human） |
| `invoke <name> <ok\|fail>` | 记录技能调用 rollup |
| `config show` | 打印 `config.json` 中的 API 相关配置（不泄露密钥） |
| `config init [--force]` | 写入默认 `config.json` |
| `config validate` | 校验 `config.json` 能否被库解析 |
| `serve [--port N]` | 仅 `127.0.0.1` 的 HTTP：`/health`、`/store`、`/status`、`POST /evolve`，以及 `chat` / `chat/stream`（SSE）/ `drc` / `kicad` / `ws`；静态根默认 `apps/web/dist`（默认端口 8788 或 `CUTECLAW_SERVE_PORT`） |
| `chat [--message TEXT]` | 单轮对话（走工具回路）；无 `--message` 进入交互式 REPL；`--session` `--json` |
| `plugin list\|load\|enable\|disable\|call` | DeepSeek Harness（Cordis，manifestVersion 1）兼容插件；`call <id> <tool> --args JSON` |
| `design open\|constraint\|read\|drc\|fit\|rank\|skills` | 工程与约束、KiCad 读取、DRC、外壳配合、候选排序（硬约束先淘汰再按代价排序） |
| `agent-tool` | 从 **stdin** 读一行 JSON，执行白名单原子工具，**stdout** 打一行 JSON；供 Web Agent 宿主 function calling 使用，详见 [agent-tools.md](agent-tools.md) |
| `working show` | 打印当前 `WorkingSet` |
| `working set <field> <文本...>` | 更新工作区一栏并保存（`field` 为 `goal` / `constraints` / `confirmed_facts` / `next_step`） |
| `fact add <key> <value...>` | 追加语义事实（confidence=1.0）并保存 |

全局选项：**`--store PATH`**（**`CUTECLAW_STORE`**）、**`--config PATH`**（**`CUTECLAW_CONFIG`**）。

退出码约定见 [cli-exit-codes.md](cli-exit-codes.md)。

## 示例

```bash
zig build run -- init
zig build run -- demo
zig build run -- status
zig build run -- validate --file examples/proposal.json
zig build run -- evolve --file examples/proposal.json --policy auto_append_only --semver 0.3.0
zig build run -- export > backup.json
```

设计面（专业领域）：

```bash
# 硬约束先淘汰，再按优化代价排序：C 飞线更短但违反 DRC，必须被淘汰
zig build run -- design rank canonical \
  --constraints '[{"id":"drc","kind":"drc_errors","limit":0,"direction":"max","severity":"hard"},{"id":"rat","kind":"rat_length","limit":900,"direction":"max","severity":"soft"}]' \
  --file benchmarks/pcb/cases.json

zig build run -- design drc canonical --path benchmarks/pcb/canonical.kicad_pcb \
  --constraints '[{"id":"clearance","kind":"clearance","limit":0.3,"direction":"min","severity":"hard"}]'

zig build run -- plugin call design-review review --plugin skills/design-review/package.json \
  --args '{"candidates":[{"id":"A","measurements":{"drc_errors":0,"rat_length_mm":820}},{"id":"B","measurements":{"drc_errors":0,"rat_length_mm":670}},{"id":"C","measurements":{"drc_errors":3,"rat_length_mm":590}}],"limits":{"drc_errors":0}}'

# 真实对话（测试 API 默认 /data/api.json，见 tests/live_chat.sh）
zig build run -- chat --message "你好，用一句话介绍你自己" --config .cuteclaw/config.json
```

一键校验：`make check`（build + test + smoke + dsh + benchmark + drc + schemas）。

## 作为库

`build.zig.zon` 包名 `cuteclaw`，根模块 `src/root.zig`。在 `build.zig` 中 `b.dependency` + `module("cuteclaw")` 后 `@import("cuteclaw")` 即可使用 `ClawRuntime`、`persist`、`evolution` 等。
