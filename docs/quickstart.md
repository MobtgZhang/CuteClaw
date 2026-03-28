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
| `serve [--port N]` | 仅 `127.0.0.1` 的 HTTP：`/health`、`/store`、`/status`、`POST /evolve`（默认端口 8788 或 `CUTECLAW_SERVE_PORT`） |
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

## 作为库

`build.zig.zon` 包名 `cuteclaw`，根模块 `src/root.zig`。在 `build.zig` 中 `b.dependency` + `module("cuteclaw")` 后 `@import("cuteclaw")` 即可使用 `ClawRuntime`、`persist`、`evolution` 等。
