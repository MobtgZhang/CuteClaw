# DeepSeek Harness（Cordis）插件兼容

兼容边界锁定 **manifestVersion 1**。控制平面始终在 Zig：插件进程只是被 Zig 调用的受控外部工具，不持有任何调度权。

## 两级兼容

1. **Level 1（纯 Zig）**：`src/plugins/manifest.zig` 解析 `package.json` 的 `dsh` 字段与 `cordis.patch.yml`。未知字段忽略但保留原始文本。
2. **Level 2（桥接进程）**：`bridges/deepseek-harness/bridge.mjs` 在独立进程中加载插件 bundle，由 `src/plugins/dsh_bridge.zig` 调用。

## 桥接协议

```text
stdin  -> {"plugin":"<id>","tool":"<name>","args":{...}}
stdout -> {"jsonrpc":"2.0","ok":true,"content":"...","meta":{...}}
```

环境变量：`PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT`（插件根目录）、`CUTECLAW_PLUGIN_ID`、`CUTECLAW_TOOL`。

兼容的插件形态（manifestVersion 1）：

```js
export const name = 'pcb-layout';
export const inject = ['tools', 'effect'];
export async function apply(ctx) {
  ctx.tools.register(defineTool('analyze', '描述', schema, async (args) => ...));
  ctx.effect('memory');
}
```

## JSON-RPC 错误码

错误也是一条响应：桥接进程把 JSON-RPC 错误对象写到 stdout 并**正常退出**，这样 Zig 宿主能把错误码原样转给调用方，而不是只看到一个进程退出码。

| 码 | 含义 |
|----|------|
| `-32700` | stdin 解析错误 |
| `-32601` | 插件未注册该工具 |
| `-32602` | 处理函数失败 |
| `-32603` | 内部错误 |

`PluginOutput.error_code` 读取 `error.code`（有符号：`ju.objNum` 是 u64，无法承载负数）。`run()` 先解析 stdout，只有在响应不可解析时才把非零退出码映射为 `error.PluginFailed`。

## 权限与效果

`src/plugins/permissions.zig` 按插件 id 授予能力，工具执行前统一校验；能力集合见 `src/sandbox/policy.zig`：`read_file`、`write_file`、`run_tool`、`network`、`plugin_exec`、`design_edit`、`evolve_write`。文件路径必须落在工作区根内（相对根以进程当前目录为基准）。

`src/plugins/kernel.zig` 加载清单、授予能力、登记**可撤销**效果，并把插件工具接入统一注册表；事件派发模式（emit / waterfall / parallel / serial / bail）见 `src/core/events.zig`。

## 命令示例

```bash
zig build run -- plugin load skills/design-review/package.json
zig build run -- plugin call design-review review --plugin skills/design-review/package.json \
  --args '{"candidates":[{"id":"A","measurements":{"drc_errors":0,"rat_length_mm":820}},{"id":"B","measurements":{"drc_errors":0,"rat_length_mm":670}},{"id":"C","measurements":{"drc_errors":3,"rat_length_mm":590}}],"limits":{"drc_errors":0}}'
# 胜出 B（代价 670），淘汰 C；未知工具 -> error: -32601
```

示例插件见 `skills/design-review`、`skills/pcb-layout`、`skills/enclosure-design`。脚本：`tests/dsh_bridge.sh`（`make dsh`）。
