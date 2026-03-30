/** 浏览器经 Vite 代理访问 Agent 宿主 /agent/* */

export interface AgentSettings {
  cacheRoot: string;
  skillsSubdir: string;
  memorySubdir: string;
  historySubdir: string;
  openaiBase: string;
  model: string;
  /** 采样温度 0–2，默认 1 */
  temperature?: number;
  /** nucleus top_p 0–1，默认 1 */
  topP?: number;
  /** 工具调用轮次上限；-1 表示尽量多轮（宿主仍有硬上限） */
  agentToolMaxRounds?: number;
  /** 服务端是否已在 settings.json 保存过 API Key（GET 从不返回明文） */
  hasOpenaiApiKey?: boolean;
  cuteclawConfigPath: string;
  showLegacyConsole: boolean;
}

export type AgentSettingsPut = Partial<AgentSettings> & {
  /** 设为新密钥；传 null 或 "" 可清除已存密钥（需显式发送） */
  openaiApiKey?: string | null;
};

export interface SkillInfo {
  id: string;
  name: string;
  description: string;
  version?: string;
  root: string;
  /** 文件夹技能或 skills 根目录下单文件 *.md */
  layout?: "folder" | "markdown_file";
}

export interface HistoryEvent {
  ts: number;
  sessionId: string;
  parentId: string | null;
  type: string;
  role: string | null;
  payload: unknown;
}

export interface SessionEntry {
  id: string;
  title?: string;
}

export interface ProjectEntry {
  id: string;
  title?: string;
}

const PROJECT_LS = "cuteclaw-agent-project";
let agentProjectId = "default";

function readStoredProject(): string {
  try {
    const v = localStorage.getItem(PROJECT_LS);
    if (v && /^[\w.-]+$/.test(v)) return v;
  } catch {
    /* */
  }
  return "default";
}

agentProjectId = typeof localStorage !== "undefined" ? readStoredProject() : "default";

export function getAgentProject(): string {
  return agentProjectId;
}

export function setAgentProject(id: string): void {
  agentProjectId = /^[\w.-]+$/.test(id) ? id : "default";
  try {
    localStorage.setItem(PROJECT_LS, agentProjectId);
  } catch {
    /* */
  }
}

function pq(url: string): string {
  const p = encodeURIComponent(getAgentProject());
  return url.includes("?") ? `${url}&project=${p}` : `${url}?project=${p}`;
}

async function j<T>(r: Response | Promise<Response>): Promise<T> {
  const res = await r;
  const data = (await res.json()) as T & { error?: string };
  if (!res.ok) throw new Error((data as { error?: string }).error ?? res.statusText);
  return data as T;
}

export const agentApi = {
  health: () => j<{ ok: boolean }>(fetch("/agent/health")),
  listProjects: () => j<{ projects: ProjectEntry[] }>(fetch("/agent/projects")),
  createProject: (id: string, title?: string) =>
    j<{ ok: boolean; id: string }>(
      fetch("/agent/projects", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, title }),
      }),
    ),
  deleteProject: (id: string) =>
    j<{ ok: boolean }>(
      fetch(`/agent/projects?id=${encodeURIComponent(id)}`, { method: "DELETE" }),
    ),
  patchProject: (id: string, title: string) =>
    j<{ ok: boolean; id: string; title: string }>(
      fetch("/agent/projects", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, title }),
      }),
    ),
  getSettings: () => j<AgentSettings>(fetch("/agent/settings")),
  /** 向当前设置中的 OpenAI 兼容 Base 请求 GET /v1/models（经宿主转发，密钥不出浏览器） */
  listOpenAiModels: () => j<{ models: string[] }>(fetch("/agent/openai/models")),
  putSettings: (s: AgentSettingsPut) =>
    j<AgentSettings>(
      fetch("/agent/settings", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(s),
      }),
    ),
  listSessions: () =>
    j<{ sessionIds: string[]; sessions: SessionEntry[] }>(fetch(pq("/agent/history/sessions"))),
  deleteSession: (id: string) =>
    j<{ ok: boolean }>(
      fetch(pq(`/agent/history/session?id=${encodeURIComponent(id)}`), { method: "DELETE" }),
    ),
  patchHistorySessions: (body: { order?: string[]; titles?: Record<string, string> }) =>
    j<{ ok: boolean; sessionIds: string[]; sessions: SessionEntry[] }>(
      fetch(pq("/agent/history/sessions"), {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }),
    ),
  moveSessionToProject: (sessionId: string, toProject: string) =>
    j<{ ok: boolean }>(
      fetch(pq("/agent/history/session/move"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: sessionId, toProject }),
      }),
    ),
  getSession: (id: string) =>
    j<{ events: HistoryEvent[] }>(
      fetch(pq(`/agent/history/session?id=${encodeURIComponent(id)}`)),
    ),
  putSession: (
    id: string,
    messages: {
      role: "user" | "assistant";
      content: string;
      /** 仅 assistant：控制台执行轨（思考/计划/工具），由服务端裁剪体积 */
      agentTrace?: unknown[];
      /** 仅 user：编辑问题产生的分支快照（variants + activeIndex） */
      userEditHistory?: unknown;
    }[],
  ) =>
    j<{ ok: boolean; count: number }>(
      fetch(pq(`/agent/history/session?id=${encodeURIComponent(id)}`), {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages }),
      }),
    ),
  appendHistory: (body: {
    sessionId: string;
    parentId?: string | null;
    type: string;
    role?: string;
    payload?: unknown;
  }) =>
    j<{ ok: boolean }>(
      fetch("/agent/history/append", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...body, project: getAgentProject() }),
      }),
    ),
  listSkills: () => j<{ skills: SkillInfo[] }>(fetch(pq("/agent/skills"))),
  deleteSkill: (id: string) =>
    j<{ ok: boolean }>(
      fetch(pq(`/agent/skills?id=${encodeURIComponent(id)}`), { method: "DELETE" }),
    ),
  readFile: (bucket: "skills" | "memory" | "history", rel: string) =>
    j<{ path: string; content: string }>(
      fetch(
        pq(`/agent/file?bucket=${bucket}&rel=${encodeURIComponent(rel)}`),
      ),
    ),
  putFile: (bucket: "skills" | "memory", rel: string, content: string) =>
    j<{ ok: boolean; path: string }>(
      fetch("/agent/file", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ bucket, rel, content, project: getAgentProject() }),
      }),
    ),
};

export type ChatSseEvent =
  | { event: "step"; data: Record<string, unknown> }
  | { event: "delta"; data: { text: string } }
  | { event: "thinking"; data: { text: string } }
  | { event: "error"; data: { message: string; detail?: string } }
  | { event: "done"; data: Record<string, unknown> };

function parseSseBlocks(chunk: string): { events: ChatSseEvent[]; rest: string } {
  const events: ChatSseEvent[] = [];
  const parts = chunk.split("\n\n");
  const complete = parts.slice(0, -1);
  const rest = parts[parts.length - 1] ?? "";
  for (const block of complete) {
    let event = "message";
    let dataLine = "";
    for (const line of block.split("\n")) {
      if (line.startsWith("event:")) event = line.slice(6).trim();
      if (line.startsWith("data:")) dataLine = line.slice(5).trim();
    }
    if (!dataLine) continue;
    try {
      const data = JSON.parse(dataLine) as Record<string, unknown>;
      events.push({ event: event as ChatSseEvent["event"], data: data as never });
    } catch {
      /* skip */
    }
  }
  return { events, rest };
}

export async function streamChat(
  messages: { role: "user" | "assistant" | "system"; content: string }[],
  sessionId: string,
  onEvent: (ev: ChatSseEvent) => void,
  signal?: AbortSignal,
): Promise<void> {
  const res = await fetch("/agent/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ messages, sessionId, project: getAgentProject() }),
    signal,
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(t || res.statusText);
  }
  const reader = res.body?.getReader();
  if (!reader) throw new Error("no body");
  const dec = new TextDecoder();
  let buf = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const { events, rest } = parseSseBlocks(buf);
    buf = rest;
    for (const ev of events) onEvent(ev);
  }
  const { events: tail } = parseSseBlocks(buf + "\n\n");
  for (const ev of tail) onEvent(ev);
}
