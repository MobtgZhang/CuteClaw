#!/usr/bin/env node
// DeepSeek Harness（Cordis）插件桥接运行时。
//
// 控制平面仍在 Zig：本进程只是被 Zig 调用的受控外部工具，不持有任何调度权。
// 协议（与 plugins/dsh_bridge.zig 一致）：
//   stdin  -> {"plugin":"<id>","tool":"<name>","args":{...}}
//   stdout -> {"ok":true,"content":"...","meta":{...}}
// 环境变量：PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT（插件根目录）、CUTECLAW_PLUGIN_ID、CUTECLAW_TOOL。
//
// 兼容的插件形态（manifestVersion 1）：
//   export const name = 'pcb-layout';
//   export const inject = ['tools', 'effect'];
//   export async function apply(ctx) {
//     ctx.tools.register(defineTool('analyze', '描述', schema, async (args) => ...));
//     ctx.effect('memory');
//   }

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const TARGET_MANIFEST_VERSION = 1;

// JSON-RPC 错误码（与 MCP / Cordis 约定一致）：
//   -32700 解析错误  -32601 方法/工具不存在  -32602 参数无效  -32603 内部错误
const RPC_PARSE_ERROR = -32700;
const RPC_METHOD_NOT_FOUND = -32601;
const RPC_INVALID_PARAMS = -32602;
const RPC_INTERNAL_ERROR = -32603;

// 错误也是一条响应：stdout 交付 JSON-RPC 错误对象，进程正常退出，
// 这样 Zig 宿主可以把错误码原样转给调用方，而不是只看到一个进程退出码。
function fail(message, meta = null, code = RPC_INTERNAL_ERROR) {
  const response = {
    jsonrpc: '2.0',
    ok: false,
    error: { code, message: String(message) },
    content: String(message),
    meta,
  };
  process.stdout.write(JSON.stringify(response) + '\n');
  process.exit(0);
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8').trim();
  if (!text) fail('empty stdin');
  try {
    return JSON.parse(text);
  } catch (e) {
    fail(`invalid stdin JSON: ${e.message}`, null, RPC_PARSE_ERROR);
  }
}

function pluginRoot() {
  const root = process.env.PLUGIN_ROOT || process.env.CLAUDE_PLUGIN_ROOT;
  if (!root) fail('PLUGIN_ROOT or CLAUDE_PLUGIN_ROOT is required');
  return path.resolve(root);
}

function readManifest(root) {
  const file = path.join(root, 'package.json');
  if (!fs.existsSync(file)) fail(`missing package.json at ${file}`);
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`invalid package.json: ${e.message}`);
  }
  const dsh = parsed.dsh || {};
  if (dsh.manifestVersion !== undefined && dsh.manifestVersion !== TARGET_MANIFEST_VERSION) {
    fail(`unsupported manifestVersion ${dsh.manifestVersion} (bridge targets ${TARGET_MANIFEST_VERSION})`);
  }
  return { raw: parsed, bundle: dsh.bundle || parsed.main || 'index.js', capabilities: parsed.capabilities || [] };
}

// Cordis 风格的工具定义：既支持 defineTool(...)，也支持直接传入对象。
export function defineTool(name, description, schema, handler) {
  if (typeof name === 'object') {
    const t = name;
    return { name: t.name, description: t.description || '', schema: t.schema || t.parameters || {}, handler: t.handler };
  }
  if (typeof name !== 'string' || !name) fail('tool name is required');
  if (typeof handler !== 'function') fail(`tool ${name} has no handler`);
  return { name, description: description || '', schema: schema || {}, handler };
}

function makeContext(pluginId, root, manifest) {
  const tools = new Map();
  const effects = [];
  const ctx = {
    plugin: { id: pluginId, root, manifest },
    env: process.env,
    tools: {
      register(tool) {
        const t = typeof tool === 'function' ? { name: tool.name || 'anonymous', description: '', schema: {}, handler: tool } : tool;
        if (!t || !t.name) fail('registered tool must have a name');
        if (typeof t.handler !== 'function') fail(`registered tool ${t.name} has no handler`);
        tools.set(t.name, t);
        return t;
      },
      list() {
        return [...tools.values()].map((t) => ({ name: t.name, description: t.description, schema: t.schema }));
      },
    },
    effect(name, payload) {
      effects.push({ name, payload: payload ?? null });
      return { name, payload: payload ?? null };
    },
    log(message) {
      process.stderr.write(`[dsh:${pluginId}] ${message}\n`);
    },
  };
  return { ctx, tools, effects };
}

function stringifyContent(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

async function main() {
  const invocation = await readStdin();
  const root = pluginRoot();
  const manifest = readManifest(root);
  const pluginId = invocation.plugin || manifest.raw.name;
  const toolName = invocation.tool;
  const args = invocation.args || {};

  const bundlePath = path.resolve(root, manifest.bundle);
  if (!fs.existsSync(bundlePath)) fail(`plugin bundle not found: ${bundlePath}`);

  let mod;
  try {
    mod = await import(pathToFileURL(bundlePath).href);
  } catch (e) {
    fail(`failed to import plugin bundle: ${e.message}`);
  }

  const { ctx, tools, effects } = makeContext(pluginId, root, manifest.raw);

  const apply = mod.apply || mod.default;
  if (typeof apply === 'function') {
    try {
      await apply(ctx);
    } catch (e) {
      fail(`plugin apply() failed: ${e.message}`);
    }
  }

  // 兼容直接导出工具数组的插件。
  if (Array.isArray(mod.tools)) {
    for (const t of mod.tools) ctx.tools.register(t);
  }

  const tool = tools.get(toolName);
  if (!tool) {
    fail(`tool not registered by plugin ${pluginId}: ${toolName}`, { available: [...tools.keys()] }, RPC_METHOD_NOT_FOUND);
  }

  let result;
  try {
    result = await tool.handler(args, ctx);
  } catch (e) {
    fail(`tool ${toolName} failed: ${e.message}`, null, RPC_INVALID_PARAMS);
  }

  const meta = {
    plugin: pluginId,
    tool: toolName,
    effects: effects,
    ...(result && typeof result === 'object' && !Array.isArray(result) ? (result.meta || {}) : {}),
  };
  const content = result && typeof result === 'object' && !Array.isArray(result) && 'content' in result ? result.content : result;

  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ok: true, content: stringifyContent(content), meta }) + '\n');
}

main().catch((e) => fail(e && e.message ? e.message : String(e)));
