/** 与 Zig 控制平面（src/server/http.zig）返回的 JSON 结构一一对应。 */

export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };

export interface Health {
  status: string;
  version: string;
  model: string;
  sessions: number;
  tools: number;
}

export interface ToolCall {
  id: string;
  name: string;
  arguments: JsonValue;
}

export interface SessionMessage {
  role: string;
  content: string;
  tool_calls?: ToolCall[];
}

export interface Session {
  id: string;
  model: string;
  system_prompt: string;
  messages: SessionMessage[];
}

export interface ToolDef {
  name: string;
  description: string;
  parameters: JsonValue;
}

export interface PluginInfo {
  id: string;
  version: string;
  bundle: string;
  enabled: boolean;
  external: boolean;
  capabilities: string[];
}

export interface SkillRollup {
  skill: string;
  invocations: number;
  successes: number;
  failures: number;
  success_rate: number;
}

export interface Metrics {
  skills: SkillRollup[];
}

export interface DrcIssue {
  rule: string;
  severity: string;
  ref: string;
  measured: number;
  limit: number;
  message: string;
}

export interface DrcReport {
  passed: boolean;
  hard_count: number;
  soft_count: number;
  issues: DrcIssue[];
}

export interface ChatReply {
  session: string;
  reply: string;
  rounds: number;
  tool_calls: number;
  outcome: string;
}

/** SSE 事件：event 名称 + 解析后的 data。 */
export interface SseEvent {
  kind: string;
  data: JsonValue;
}

export interface DeltaEvent {
  text: string;
}

export interface ToolCallEvent {
  id: string;
  name: string;
  arguments: string;
}

export interface ToolResultEvent {
  tool: string;
  ok: boolean;
  content: string;
}

export interface DoneEvent {
  text: string;
  rounds: number;
  finish_reason: string;
  prompt_tokens: number;
  completion_tokens: number;
}

export interface ChatEntry {
  id: number;
  role: "user" | "assistant" | "tool" | "system";
  text: string;
  tool?: string;
  ok?: boolean;
  rounds?: number;
  tokens?: number;
}

export interface RpcError {
  code: number;
  message: string;
}

export interface RpcResponse {
  jsonrpc: string;
  id: number;
  result?: JsonValue;
  error?: RpcError;
}
