import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import MDEditor from "@uiw/react-md-editor";
import MarkdownPreview from "@uiw/react-markdown-preview";
import "@uiw/react-md-editor/markdown-editor.css";
import "@uiw/react-markdown-preview/markdown.css";
import {
  agentApi,
  getAgentProject,
  setAgentProject,
  streamChat,
  type AgentSettings,
  type AgentSettingsPut,
  type ChatSseEvent,
  type ProjectEntry,
  type SessionEntry,
  type SkillInfo,
} from "@/agent/api";
import { api } from "@/api/client";
import type { ProposalJson } from "@/types/proposal";
import { LegacyConsole } from "@/pages/LegacyConsole";
import { ModelPopover } from "@/components/ModelPopover";

type PlanStep = {
  id: string;
  title: string;
  status: string;
  detail?: string;
};

/** 单次助手回复内按时间顺序排列：上下文 → 思考 → 计划 → 工具 → … → 结束 */
type RunFlowItem =
  | { kind: "context"; id: string; at: number; title: string; body: string }
  | { kind: "thinking"; id: string; at: number; text: string }
  | {
      kind: "plan";
      id: string;
      at: number;
      round: number;
      thought?: string;
      steps: PlanStep[];
    }
  | { kind: "tool_call"; id: string; at: number; round: number; name: string; body: string }
  | { kind: "tool_result"; id: string; at: number; round: number; name: string; ok: boolean; body: string }
  | { kind: "lifecycle"; id: string; at: number; title: string; body: string }
  | { kind: "error"; id: string; at: number; title: string; body: string };

type Msg = {
  localId: string;
  role: "user" | "assistant";
  content: string;
  /** 该轮助手回复的执行轨（思考 / 计划 / 工具），落盘在 agentTrace */
  agentTrace?: RunFlowItem[];
};

function newLocalId(): string {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `m-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

const MAX_SAVED_TRACE_ITEMS = 320;

function clampTraceForDisk(t: RunFlowItem[] | undefined): RunFlowItem[] | undefined {
  if (!t?.length) return undefined;
  if (t.length <= MAX_SAVED_TRACE_ITEMS) return t;
  return t.slice(-MAX_SAVED_TRACE_ITEMS);
}

function messagesToDisk(
  msgs: Msg[],
): { role: "user" | "assistant"; content: string; agentTrace?: RunFlowItem[] }[] {
  return msgs.map(({ role, content, agentTrace }) => {
    const c = clampTraceForDisk(agentTrace);
    if (role === "assistant" && c?.length)
      return { role, content, agentTrace: c };
    return { role, content };
  });
}

function deserializeAgentTrace(raw: unknown): RunFlowItem[] | undefined {
  if (!Array.isArray(raw) || raw.length === 0) return undefined;
  const out: RunFlowItem[] = [];
  for (const el of raw) {
    if (!el || typeof el !== "object") continue;
    const o = el as RunFlowItem;
    if (typeof o.kind !== "string" || typeof (o as { id?: unknown }).id !== "string") continue;
    out.push(o);
  }
  return out.length ? out : undefined;
}

/** 落盘前去掉末尾空的 assistant，避免 JSONL 垃圾行（若有执行轨则保留以便展示中断过程） */
function trimTrailingEmptyAssistant(msgs: Msg[]): Msg[] {
  const m = [...msgs];
  while (m.length > 0 && m[m.length - 1]!.role === "assistant") {
    const last = m[m.length - 1]!;
    const emptyText = last.content.trim() === "";
    const hasTrace = (last.agentTrace?.length ?? 0) > 0;
    if (!emptyText || hasTrace) break;
    m.pop();
  }
  return m;
}

const MODEL_LIST_KEY = "cuteclaw-agent-model-list";
const THEME_KEY = "cuteclaw-agent-theme";

function readStoredTheme(): "dark" | "light" {
  try {
    const v = localStorage.getItem(THEME_KEY);
    if (v === "light" || v === "dark") return v;
  } catch {
    /* */
  }
  return "dark";
}

function loadStoredModels(): string[] {
  try {
    const raw = localStorage.getItem(MODEL_LIST_KEY);
    if (!raw) return [];
    const j = JSON.parse(raw) as unknown;
    if (!Array.isArray(j)) return [];
    const ids = j.filter((x): x is string => typeof x === "string" && x.trim() !== "").map((x) => x.trim());
    return [...new Set(ids)];
  } catch {
    return [];
  }
}

function saveStoredModels(ids: string[]) {
  localStorage.setItem(MODEL_LIST_KEY, JSON.stringify(ids));
}

function newSessionId(): string {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `s-${Date.now()}`;
}

const NEW_SKILL_MARKDOWN = `# 新技能

用一两句话说明这个技能做什么（会出现在 Agent 系统提示的技能摘要中）。

## 说明
在此处编写详细说明或步骤。
`;

function isValidSkillFolderId(id: string): boolean {
  const t = id.trim();
  if (t.length < 1 || t.length > 64) return false;
  return /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(t);
}

function defaultClawJsonForSkill(folderId: string, displayName: string): string {
  const name = displayName.trim() || folderId;
  return `${JSON.stringify({ name, description: "", version: "0.1.0" }, null, 2)}\n`;
}

const LS_ZONE_PROJECTS = "cuteclaw-zone-projects";
const LS_ZONE_SKILLS = "cuteclaw-zone-skills";
const LS_ZONE_CHATS = "cuteclaw-zone-chats";

function lsBool(key: string, defaultVal: boolean): boolean {
  try {
    const v = localStorage.getItem(key);
    if (v === "0") return false;
    if (v === "1") return true;
  } catch {
    /* */
  }
  return defaultVal;
}

function persistLsBool(key: string, val: boolean) {
  try {
    localStorage.setItem(key, val ? "1" : "0");
  } catch {
    /* */
  }
}

const RUN_FLOW_BODY_MAX = 14_000;

function truncRunBody(s: string): string {
  return s.length > RUN_FLOW_BODY_MAX ? s.slice(0, RUN_FLOW_BODY_MAX) + "\n…" : s;
}

function IconCopy() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <rect x="9" y="9" width="13" height="13" rx="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function IconEdit() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
      <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
    </svg>
  );
}

function IconRegenerate() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <path d="M23 4v6h-6" />
      <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
    </svg>
  );
}

function IconTrash() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6h14z" />
    </svg>
  );
}

export function AgentConsole() {
  const [settings, setSettings] = useState<AgentSettings | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [legacyOpen, setLegacyOpen] = useState(false);
  const [evolveOpen, setEvolveOpen] = useState(false);
  const [sessionList, setSessionList] = useState<SessionEntry[]>([]);
  const [projects, setProjects] = useState<ProjectEntry[]>([]);
  const [projectId, setProjectId] = useState(() => getAgentProject());
  const [sessionId, setSessionId] = useState(newSessionId);
  const [theme, setTheme] = useState<"dark" | "light">(readStoredTheme);
  const [streamDeltaSeen, setStreamDeltaSeen] = useState(false);
  const [messages, setMessages] = useState<Msg[]>([]);
  const [editingLocalId, setEditingLocalId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");
  const [input, setInput] = useState("");
  const [runFlow, setRunFlow] = useState<RunFlowItem[]>([]);
  const [streamingAssistantId, setStreamingAssistantId] = useState<string | null>(null);
  const runFlowRef = useRef<RunFlowItem[]>([]);
  const skillLoadGenRef = useRef(0);
  const [zoneProjectsOpen, setZoneProjectsOpen] = useState(() => lsBool(LS_ZONE_PROJECTS, true));
  const [zoneSkillsOpen, setZoneSkillsOpen] = useState(() => lsBool(LS_ZONE_SKILLS, true));
  const [zoneChatsOpen, setZoneChatsOpen] = useState(() => lsBool(LS_ZONE_CHATS, true));
  const [rowMenuId, setRowMenuId] = useState<string | null>(null);
  const [skills, setSkills] = useState<SkillInfo[]>([]);
  const [skillSel, setSkillSel] = useState<SkillInfo | null>(null);
  const [editorContent, setEditorContent] = useState("");
  const [editorRel, setEditorRel] = useState<string | null>(null);
  const [editorBaseline, setEditorBaseline] = useState<string | null>(null);
  const [fileSaving, setFileSaving] = useState(false);
  const [skillDrawerOpen, setSkillDrawerOpen] = useState(false);
  const [isCreatingSkill, setIsCreatingSkill] = useState(false);
  const [newSkillFolderId, setNewSkillFolderId] = useState("");
  const [newSkillDisplayName, setNewSkillDisplayName] = useState("");
  const [skillDocMode, setSkillDocMode] = useState<"markdown" | "preview">("markdown");
  const [extraModels, setExtraModels] = useState<string[]>(() => loadStoredModels());
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const thinkingMergeRef = useRef(true);
  const runFlowPanelRef = useRef<HTMLDivElement>(null);

  const [draftSettings, setDraftSettings] = useState<Partial<AgentSettings>>({});
  const [settingsApiKeyDraft, setSettingsApiKeyDraft] = useState("");
  const [settingsClearApiKey, setSettingsClearApiKey] = useState(false);

  const loadAll = useCallback(async () => {
    try {
      const [s, sk, sess, pr] = await Promise.all([
        agentApi.getSettings(),
        agentApi.listSkills(),
        agentApi.listSessions(),
        agentApi.listProjects(),
      ]);
      setSettings(s);
      setDraftSettings(s);
      setSkills(sk.skills);
      setSessionList(sess.sessions ?? sess.sessionIds.map((id) => ({ id })));
      setProjects(pr.projects);
      let cur = getAgentProject();
      if (!pr.projects.some((p) => p.id === cur)) {
        setAgentProject("default");
        setProjectId("default");
        cur = "default";
        const [sk2, sess2] = await Promise.all([agentApi.listSkills(), agentApi.listSessions()]);
        setSkills(sk2.skills);
        setSessionList(sess2.sessions ?? sess2.sessionIds.map((x) => ({ id: x })));
      }
      setErr(null);
    } catch (e) {
      setErr(`Agent 宿主未就绪？请确认 npm run dev 已启动 agent（端口 8790）。 ${String(e)}`);
    }
  }, []);

  /** 未指定或非法项目时归一到 default，并同步 React 中的 projectId */
  const ensureDefaultProjectScope = useCallback(() => {
    let cur = getAgentProject();
    if (!cur || !/^[\w.-]+$/.test(cur) || cur.startsWith("_")) {
      setAgentProject("default");
      cur = "default";
    }
    setProjectId(cur);
  }, []);

  const switchProject = useCallback(
    (id: string) => {
      if (!/^[\w.-]+$/.test(id) || id === projectId) return;
      setAgentProject(id);
      setProjectId(id);
      setSessionId(newSessionId());
      setMessages([]);
      setRunFlow([]);
      setEditingLocalId(null);
      setSkillSel(null);
      setEditorContent("");
      setEditorRel(null);
      setEditorBaseline(null);
      void loadAll();
    },
    [projectId, loadAll],
  );

  const createNewProject = async () => {
    const raw = window.prompt("新项目 ID（仅字母、数字、._-）", "");
    if (raw === null) return;
    const id = raw.trim();
    if (!/^[\w.-]+$/.test(id) || id.startsWith("_")) {
      setErr("项目 ID 无效或不能以 _ 开头。");
      return;
    }
    try {
      await agentApi.createProject(id, id);
      switchProject(id);
    } catch (e) {
      setErr(String(e));
    }
  };

  const deleteProjectById = async (id: string) => {
    if (id === "default") return;
    if (!window.confirm(`删除项目「${id}」及其中全部技能与对话？不可恢复。`)) return;
    try {
      await agentApi.deleteProject(id);
      if (projectId === id) {
        setAgentProject("default");
        setProjectId("default");
        setSessionId(newSessionId());
        setMessages([]);
        setRunFlow([]);
        setEditingLocalId(null);
        setSkillSel(null);
        setEditorContent("");
        setEditorRel(null);
        setEditorBaseline(null);
      }
      await loadAll();
    } catch (e) {
      setErr(String(e));
    }
  };

  const renameProjectById = async (id: string) => {
    const p = projects.find((x) => x.id === id);
    const raw = window.prompt("项目显示名称", p?.title?.trim() || p?.id || id);
    if (raw === null) return;
    try {
      await agentApi.patchProject(id, raw.trim() || id);
      await loadAll();
    } catch (e) {
      setErr(String(e));
    }
  };

  const deleteSkillById = async (sk: SkillInfo) => {
    if (!window.confirm(`删除技能「${sk.name}」（目录 ${sk.id}）？不可恢复。`)) return;
    try {
      await agentApi.deleteSkill(sk.id);
      if (skillSel?.id === sk.id) {
        setSkillSel(null);
        setEditorRel(null);
        setEditorContent("");
        setEditorBaseline(null);
      }
      await loadAll();
    } catch (e) {
      setErr(String(e));
    }
  };

  const moveSessionToOtherProject = useCallback(
    async (id: string) => {
      const targets = projects.filter((p) => p.id !== projectId);
      if (targets.length === 0) {
        setErr("没有其他项目可移动。");
        return;
      }
      const hint = targets.map((p) => `${p.id}${p.title ? ` (${p.title})` : ""}`).join("\n");
      const raw = window.prompt(`输入要移入的项目 ID：\n${hint}`, targets[0]!.id);
      if (raw === null) return;
      const to = raw.trim();
      if (!targets.some((p) => p.id === to)) {
        setErr("无效的目标项目。");
        return;
      }
      try {
        await agentApi.moveSessionToProject(id, to);
        if (sessionId === id) {
          setSessionId(newSessionId());
          setMessages([]);
          setRunFlow([]);
          setEditingLocalId(null);
        }
        const next = await agentApi.listSessions();
        setSessionList(next.sessions ?? next.sessionIds.map((x) => ({ id: x })));
      } catch (e) {
        setErr(String(e));
      }
    },
    [projects, projectId, sessionId],
  );

  useEffect(() => {
    void loadAll();
  }, [loadAll]);

  useEffect(() => {
    if (settingsOpen) {
      setSettingsApiKeyDraft("");
      setSettingsClearApiKey(false);
    }
  }, [settingsOpen]);

  useEffect(() => {
    runFlowRef.current = runFlow;
  }, [runFlow]);

  useEffect(() => {
    if (!streamingAssistantId) return;
    const el = runFlowPanelRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [runFlow, streamingAssistantId]);

  useEffect(() => {
    if (!rowMenuId) return;
    const onDown = (e: MouseEvent) => {
      const t = e.target as HTMLElement;
      if (t.closest("[data-gpt-row-menu-root]")) return;
      setRowMenuId(null);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [rowMenuId]);

  const refreshModelList = useCallback(async () => {
    const s = await agentApi.getSettings();
    setSettings(s);
    setDraftSettings((d) => ({ ...d, model: s.model }));
    let remote: string[] = [];
    try {
      const r = await agentApi.listOpenAiModels();
      remote = Array.isArray(r.models) ? r.models.filter((x) => typeof x === "string" && x.trim()) : [];
    } catch {
      /* 无密钥或上游失败时仍合并当前 model */
    }
    const m = s.model?.trim();
    setExtraModels((prev) => {
      const next = [...new Set([...remote, ...(m ? [m] : []), ...prev])];
      saveStoredModels(next);
      return next;
    });
  }, []);

  const persistSession = useCallback(
    async (msgs: Msg[]) => {
      const disk = messagesToDisk(trimTrailingEmptyAssistant(msgs));
      await agentApi.putSession(sessionId, disk);
      try {
        const s = await agentApi.listSessions();
        setSessionList(s.sessions ?? s.sessionIds.map((id) => ({ id })));
      } catch {
        /* */
      }
    },
    [sessionId],
  );

  const runAssistantStream = useCallback(
    async (
      forApi: { role: "user" | "assistant"; content: string }[],
      initialDraft: Msg[],
      assistantLocalId: string,
    ) => {
      setLoading(true);
      setStreamDeltaSeen(false);
      setStreamingAssistantId(assistantLocalId);
      setRunFlow([]);
      thinkingMergeRef.current = true;
      setErr(null);
      abortRef.current?.abort();
      abortRef.current = new AbortController();
      let draft = initialDraft;
      let assistantBuf = "";
      const onEvent = (ev: ChatSseEvent) => {
        if (ev.event === "step") {
          const d = ev.data as Record<string, unknown>;
          const kind = typeof d.kind === "string" ? d.kind : "";
          if (kind === "skills_loaded") {
            const n = typeof d.count === "number" ? d.count : 0;
            setRunFlow((prev) => [
              ...prev,
              {
                kind: "context",
                id: newLocalId(),
                at: Date.now(),
                title: `上下文 · 已加载 ${n} 项技能`,
                body: truncRunBody(JSON.stringify(d, null, 2)),
              },
            ]);
            return;
          }
          if (kind === "request_start") {
            setRunFlow((prev) => [
              ...prev,
              {
                kind: "context",
                id: newLocalId(),
                at: Date.now(),
                title: "请求 · 连接上游模型",
                body: truncRunBody(JSON.stringify(d, null, 2)),
              },
            ]);
            return;
          }
          if (kind === "plan_update") {
            thinkingMergeRef.current = false;
            const round = typeof d.round === "number" ? d.round : 0;
            const thought = typeof d.thought === "string" ? d.thought : undefined;
            const stepsRaw = d.steps;
            const steps: PlanStep[] = [];
            if (Array.isArray(stepsRaw)) {
              for (let si = 0; si < stepsRaw.length; si++) {
                const x = stepsRaw[si];
                if (!x || typeof x !== "object") continue;
                const o = x as Record<string, unknown>;
                const title = typeof o.title === "string" ? o.title : `步骤 ${si + 1}`;
                const status = typeof o.status === "string" ? o.status : "pending";
                const id = typeof o.id === "string" ? o.id : `p${si}`;
                const detail = typeof o.detail === "string" ? o.detail : undefined;
                steps.push({ id, title, status, detail });
              }
            }
            if (steps.length === 0) return;
            setRunFlow((prev) => [
              ...prev,
              {
                kind: "plan",
                id: newLocalId(),
                at: Date.now(),
                round,
                thought,
                steps,
              },
            ]);
            return;
          }
          if (kind === "tool_call") {
            thinkingMergeRef.current = false;
            const name = typeof d.name === "string" ? d.name : "?";
            const round = typeof d.round === "number" ? d.round : 0;
            setRunFlow((prev) => [
              ...prev,
              {
                kind: "tool_call",
                id: newLocalId(),
                at: Date.now(),
                round,
                name,
                body: truncRunBody(JSON.stringify(d.args ?? {}, null, 2)),
              },
            ]);
            return;
          }
          if (kind === "tool_result") {
            thinkingMergeRef.current = true;
            const name = typeof d.name === "string" ? d.name : "?";
            const round = typeof d.round === "number" ? d.round : 0;
            const ok = d.ok === true;
            const body = ok
              ? truncRunBody(JSON.stringify(d.result ?? {}, null, 2))
              : truncRunBody(String(d.err ?? "error"));
            setRunFlow((prev) => [
              ...prev,
              {
                kind: "tool_result",
                id: newLocalId(),
                at: Date.now(),
                round,
                name,
                ok,
                body,
              },
            ]);
            return;
          }
          setRunFlow((prev) => [
            ...prev,
            {
              kind: "context",
              id: newLocalId(),
              at: Date.now(),
              title: kind ? `步骤 · ${kind}` : "步骤",
              body: truncRunBody(JSON.stringify(d, null, 2)),
            },
          ]);
          return;
        }
        if (ev.event === "thinking" && ev.data && typeof ev.data.text === "string") {
          const text = ev.data.text;
          setRunFlow((prev) => {
            const last = prev[prev.length - 1];
            if (thinkingMergeRef.current && last?.kind === "thinking") {
              return [...prev.slice(0, -1), { ...last, text: last.text + text }];
            }
            return [...prev, { kind: "thinking", id: newLocalId(), at: Date.now(), text }];
          });
          return;
        }
        if (ev.event === "delta" && ev.data && typeof ev.data.text === "string") {
          thinkingMergeRef.current = false;
          setStreamDeltaSeen(true);
          assistantBuf += ev.data.text;
          draft = draft.map((m) =>
            m.localId === assistantLocalId ? { ...m, content: assistantBuf } : m,
          );
          setMessages(draft);
        }
        if (ev.event === "error") {
          const msg = (ev.data as { message?: string }).message ?? "error";
          setRunFlow((prev) => [
            ...prev,
            { kind: "error", id: newLocalId(), at: Date.now(), title: "错误", body: msg },
          ]);
          setErr(msg);
        }
        if (ev.event === "done") {
          setRunFlow((prev) => [
            ...prev,
            {
              kind: "lifecycle",
              id: newLocalId(),
              at: Date.now(),
              title: "流结束",
              body: "响应已完成。",
            },
          ]);
        }
      };
      try {
        await streamChat(forApi, sessionId, onEvent, abortRef.current.signal);
      } catch (e) {
        if ((e as Error).name === "AbortError") {
          setRunFlow((prev) => [
            ...prev,
            {
              kind: "lifecycle",
              id: newLocalId(),
              at: Date.now(),
              title: "已中止",
              body: "已取消本次请求。",
            },
          ]);
        } else {
          setErr(String(e));
        }
      } finally {
        const traceSnap = [...runFlowRef.current];
        draft = draft.map((m) =>
          m.localId === assistantLocalId
            ? {
                ...m,
                content: assistantBuf,
                agentTrace: traceSnap.length > 0 ? traceSnap : undefined,
              }
            : m,
        );
        const trimmed = trimTrailingEmptyAssistant(draft);
        setMessages(trimmed);
        setStreamingAssistantId(null);
        setRunFlow([]);
        setLoading(false);
        try {
          await persistSession(trimmed);
        } catch (pe) {
          setErr(String(pe));
        }
      }
    },
    [sessionId, persistSession],
  );

  const handleSend = async () => {
    const t = input.trim();
    if (!t || loading) return;
    ensureDefaultProjectScope();
    setInput("");
    setEditingLocalId(null);
    const userMsg: Msg = { localId: newLocalId(), role: "user", content: t };
    const assistantLocalId = newLocalId();
    const draft: Msg[] = [
      ...messages,
      userMsg,
      { localId: assistantLocalId, role: "assistant", content: "" },
    ];
    setMessages(draft);
    const forApi = [...messages, userMsg].map(({ role, content }) => ({ role, content }));
    await runAssistantStream(forApi, draft, assistantLocalId);
  };

  const regenerateFromAssistant = async (assistantLocalId: string) => {
    if (loading) return;
    const idx = messages.findIndex((m) => m.localId === assistantLocalId);
    if (idx < 0) return;
    let j = idx - 1;
    while (j >= 0 && messages[j]!.role !== "user") j--;
    if (j < 0) return;
    const userMsg = messages[j]!;
    const prefix = messages.slice(0, j);
    const newAsstId = newLocalId();
    const draft: Msg[] = [
      ...prefix,
      userMsg,
      { localId: newAsstId, role: "assistant", content: "" },
    ];
    setMessages(draft);
    setRunFlow([]);
    setEditingLocalId(null);
    const forApi = [
      ...prefix.map(({ role, content }) => ({ role, content })),
      { role: "user" as const, content: userMsg.content },
    ];
    await runAssistantStream(forApi, draft, newAsstId);
  };

  const saveSettings = async () => {
    try {
      const payload: AgentSettingsPut = { ...draftSettings };
      delete (payload as { hasOpenaiApiKey?: boolean }).hasOpenaiApiKey;
      if (settingsClearApiKey) {
        payload.openaiApiKey = null;
      } else if (settingsApiKeyDraft.trim()) {
        payload.openaiApiKey = settingsApiKeyDraft.trim();
      }
      const s = await agentApi.putSettings(payload);
      setSettings(s);
      setSettingsOpen(false);
      setSettingsApiKeyDraft("");
      setSettingsClearApiKey(false);
      await loadAll();
    } catch (e) {
      setErr(String(e));
    }
  };

  const loadSession = async (id: string) => {
    setSessionId(id);
    setEditingLocalId(null);
    try {
      const { events } = await agentApi.getSession(id);
      const msgs: Msg[] = [];
      for (const ev of events) {
        if (ev.type === "user_message" && ev.payload && typeof ev.payload === "object") {
          const p = ev.payload as { text?: string };
          if (p.text !== undefined)
            msgs.push({ localId: newLocalId(), role: "user", content: p.text });
        }
        if (ev.type === "assistant_message" && ev.payload && typeof ev.payload === "object") {
          const p = ev.payload as { text?: string; agentTrace?: unknown };
          if (p.text !== undefined)
            msgs.push({
              localId: newLocalId(),
              role: "assistant",
              content: p.text,
              agentTrace: deserializeAgentTrace(p.agentTrace),
            });
        }
      }
      setMessages(msgs);
      setRunFlow([]);
    } catch (e) {
      setErr(String(e));
    }
  };

  const mergedSessionRows = useMemo((): SessionEntry[] => {
    if (sessionList.some((s) => s.id === sessionId)) return sessionList;
    return [{ id: sessionId }, ...sessionList];
  }, [sessionList, sessionId]);

  const sessionOnDisk = useCallback(
    (id: string) => sessionList.some((s) => s.id === id),
    [sessionList],
  );

  const renameSessionRow = async (id: string) => {
    if (!sessionOnDisk(id)) return;
    const cur = sessionList.find((s) => s.id === id);
    const n = window.prompt("会话标题", cur?.title ?? "");
    if (n === null) return;
    try {
      const r = await agentApi.patchHistorySessions({ titles: { [id]: n.trim() } });
      setSessionList(r.sessions);
    } catch (e) {
      setErr(String(e));
    }
  };

  const deleteSessionRow = async (id: string) => {
    if (!sessionOnDisk(id)) {
      if (id === sessionId) {
        setSessionId(newSessionId());
        setMessages([]);
        setRunFlow([]);
        setEditingLocalId(null);
      }
      return;
    }
    if (!window.confirm("确定删除此对话？不可恢复。")) return;
    try {
      await agentApi.deleteSession(id);
      const next = await agentApi.listSessions();
      const rows = next.sessions ?? next.sessionIds.map((x) => ({ id: x }));
      setSessionList(rows);
      if (sessionId === id) {
        const remain = rows.filter((s) => s.id !== id);
        if (remain.length) {
          await loadSession(remain[0]!.id);
        } else {
          setSessionId(newSessionId());
          setMessages([]);
          setRunFlow([]);
          setEditingLocalId(null);
        }
      }
    } catch (e) {
      setErr(String(e));
    }
  };

  const moveSessionRow = async (id: string, delta: number) => {
    if (!sessionOnDisk(id)) return;
    const ids = sessionList.map((s) => s.id);
    const i = ids.indexOf(id);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return;
    const order = [...ids];
    [order[i], order[j]] = [order[j]!, order[i]!];
    try {
      const r = await agentApi.patchHistorySessions({ order });
      setSessionList(r.sessions);
    } catch (e) {
      setErr(String(e));
    }
  };

  useEffect(() => {
    try {
      localStorage.setItem(THEME_KEY, theme);
    } catch {
      /* */
    }
    document.documentElement.dataset.theme = theme;
    document.documentElement.setAttribute("data-color-mode", theme === "light" ? "light" : "dark");
  }, [theme]);

  const startEditMessage = (m: Msg) => {
    setEditingLocalId(m.localId);
    setEditDraft(m.content);
  };

  const cancelEditMessage = () => {
    if (editingLocalId) {
      const cur = messages.find((m) => m.localId === editingLocalId);
      if (cur && cur.content === "" && editDraft === "") {
        setMessages((prev) => prev.filter((m) => m.localId !== editingLocalId));
        setEditingLocalId(null);
        setEditDraft("");
        return;
      }
    }
    setEditingLocalId(null);
    setEditDraft("");
  };

  const saveEditMessage = async () => {
    if (!editingLocalId) return;
    const next = messages.map((m) =>
      m.localId === editingLocalId ? { ...m, content: editDraft } : m,
    );
    setMessages(next);
    setEditingLocalId(null);
    setEditDraft("");
    try {
      await persistSession(next);
    } catch (e) {
      setErr(String(e));
    }
  };

  const deleteMessage = async (localId: string) => {
    const next = messages.filter((m) => m.localId !== localId);
    setMessages(next);
    if (editingLocalId === localId) cancelEditMessage();
    try {
      await persistSession(next);
    } catch (e) {
      setErr(String(e));
    }
  };

  const copyPlain = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      setErr("无法复制到剪贴板。");
    }
  };

  const loadSkillFile = useCallback((sk: SkillInfo) => {
    setIsCreatingSkill(false);
    setNewSkillFolderId("");
    setNewSkillDisplayName("");
    const gen = ++skillLoadGenRef.current;
    void (async () => {
      const attempts =
        sk.layout === "markdown_file"
          ? ([`${sk.id}.md`] as const)
          : ([`${sk.id}/README.md`, `${sk.id}/SKILL.md`, `${sk.id}/claw.json`] as const);
      for (const rel of attempts) {
        try {
          const r = await agentApi.readFile("skills", rel);
          if (gen !== skillLoadGenRef.current) return;
          setEditorContent(r.content);
          setEditorRel(rel);
          setEditorBaseline(r.content);
          setErr(null);
          return;
        } catch {
          /* try next */
        }
      }
      if (gen !== skillLoadGenRef.current) return;
      setEditorContent("(无 README.md / SKILL.md / claw.json，或后缀不在白名单)");
      setEditorRel(null);
      setEditorBaseline(null);
    })();
  }, []);

  /** 侧栏点击：打开抽屉；默认预览便于阅读，菜单「编辑」进入 Markdown 模式 */
  const openSkillDrawer = useCallback((sk: SkillInfo, docMode: "markdown" | "preview" = "preview") => {
    setSkillSel(sk);
    setSkillDocMode(docMode);
    setSkillDrawerOpen(true);
    loadSkillFile(sk);
  }, [loadSkillFile]);

  const openNewSkillDraft = useCallback(() => {
    ensureDefaultProjectScope();
    setIsCreatingSkill(true);
    setNewSkillFolderId("");
    setNewSkillDisplayName("");
    setSkillSel(null);
    setEditorContent(NEW_SKILL_MARKDOWN);
    setEditorRel(null);
    setEditorBaseline("");
    setSkillDocMode("markdown");
    setSkillDrawerOpen(true);
    setErr(null);
  }, [ensureDefaultProjectScope]);

  const closeSkillDrawer = useCallback(() => {
    setSkillDrawerOpen(false);
    setIsCreatingSkill(false);
    setNewSkillFolderId("");
    setNewSkillDisplayName("");
  }, []);

  const saveSkillFile = async () => {
    setFileSaving(true);
    try {
      if (isCreatingSkill) {
        const folder = newSkillFolderId.trim();
        if (!isValidSkillFolderId(folder)) {
          setErr("技能目录名须为 1–64 字符，以字母或数字开头，仅含字母、数字、下划线、连字符与点。");
          return;
        }
        if (!editorContent.trim()) {
          setErr("请先填写 SKILL.md 内容。");
          return;
        }
        const { skills: existing } = await agentApi.listSkills();
        if (existing.some((s) => s.id === folder)) {
          setErr(`技能目录「${folder}」已存在，请换一个名字或从左侧选择已有技能。`);
          return;
        }
        const relMd = `${folder}/SKILL.md`;
        const relClaw = `${folder}/claw.json`;
        await agentApi.putFile("skills", relMd, editorContent);
        await agentApi.putFile("skills", relClaw, defaultClawJsonForSkill(folder, newSkillDisplayName));
        setIsCreatingSkill(false);
        setNewSkillFolderId("");
        setNewSkillDisplayName("");
        setEditorRel(relMd);
        setEditorBaseline(editorContent);
        await loadAll();
        const { skills: after } = await agentApi.listSkills();
        const sk = after.find((s) => s.id === folder);
        if (sk) setSkillSel(sk);
        setErr(null);
        return;
      }
      if (!editorRel) return;
      await agentApi.putFile("skills", editorRel, editorContent);
      setEditorBaseline(editorContent);
      setErr(null);
      await loadAll();
    } catch (e) {
      setErr(String(e));
    } finally {
      setFileSaving(false);
    }
  };

  const editorDirty = Boolean(editorRel) && editorContent !== editorBaseline;
  const newSkillCanSave =
    isCreatingSkill &&
    isValidSkillFolderId(newSkillFolderId) &&
    editorContent.trim().length > 0;
  const skillDocPathLabel = isCreatingSkill
    ? `${newSkillFolderId.trim() || "…"}/SKILL.md`
    : editorRel ?? "—";
  const skillDocButtonEnabled = isCreatingSkill || Boolean(skillSel && editorRel);

  const mdColorMode = theme === "light" ? "light" : "dark";

  const welcomeSuggestions = [
    "用 Zig 写一个读取小文件的示例",
    "解释一下 Agent 侧栏会话与 manifest 的作用",
    "如何把技能文档改成预览模式？",
    "列出当前可用的模型并选一个",
  ];

  const renderRunFlowList = (flow: RunFlowItem[], live: boolean) =>
    flow.map((item) => {
      const last = flow[flow.length - 1];
      const thinkingSpinner =
        live &&
        item.kind === "thinking" &&
        last?.id === item.id &&
        !streamDeltaSeen;

      switch (item.kind) {
        case "context":
        case "lifecycle":
          return (
            <details key={item.id} className="gpt-run-flow-step gpt-run-flow-context">
              <summary className="gpt-run-flow-sum">{item.title}</summary>
              <pre className="gpt-run-flow-pre">{item.body}</pre>
            </details>
          );
        case "error":
          return (
            <details key={item.id} className="gpt-run-flow-step gpt-run-flow-error" open>
              <summary className="gpt-run-flow-sum">{item.title}</summary>
              <pre className="gpt-run-flow-pre">{item.body}</pre>
            </details>
          );
        case "thinking":
          return (
            <details key={item.id} className="gpt-run-flow-step gpt-run-flow-thinking" open>
              <summary className="gpt-run-flow-sum gpt-run-flow-sum-thinking">
                {thinkingSpinner ? (
                  <span className="gpt-thinking-spinner" aria-hidden />
                ) : (
                  <span className="gpt-thinking-spinner gpt-thinking-spinner-off" aria-hidden />
                )}
                <span>思考</span>
              </summary>
              <div className="gpt-run-flow-thinking-body gpt-md gpt-thinking-md" data-color-mode={mdColorMode}>
                <MarkdownPreview
                  source={item.text.trim() ? item.text : " "}
                  disableCopy={false}
                  wrapperElement={{ "data-color-mode": mdColorMode }}
                />
              </div>
            </details>
          );
        case "tool_call":
          return (
            <div key={item.id} className="gpt-run-flow-step gpt-run-flow-tool gpt-run-flow-tool-call">
              <div className="gpt-run-flow-tool-h">调用工具 · {item.name}</div>
              <pre className="gpt-run-flow-pre">{item.body}</pre>
            </div>
          );
        case "tool_result":
          return (
            <div
              key={item.id}
              className={`gpt-run-flow-step gpt-run-flow-tool gpt-run-flow-tool-result${item.ok ? " is-ok" : " is-err"}`}
            >
              <div className="gpt-run-flow-tool-h">
                {item.ok ? "完成" : "失败"} · {item.name}
              </div>
              <pre className="gpt-run-flow-pre">{item.body}</pre>
            </div>
          );
        case "plan":
          return (
            <div key={item.id} className="gpt-run-flow-step gpt-run-flow-plan">
              <div className="gpt-run-flow-plan-h">任务规划</div>
              {item.thought ? <p className="gpt-run-flow-plan-thought">{item.thought}</p> : null}
              <ul className="gpt-plan-todo-list" aria-label="计划步骤">
                {item.steps.map((s) => (
                  <li
                    key={s.id}
                    className={`gpt-plan-todo-item gpt-plan-todo-${(s.status || "pending").replace(/[^a-z_]/g, "_")}`}
                  >
                    <span className="gpt-plan-todo-status" title={s.status}>
                      {s.status === "done"
                        ? "✓"
                        : s.status === "in_progress"
                          ? "›"
                          : s.status === "cancelled"
                            ? "✕"
                            : "○"}
                    </span>
                    <span className="gpt-plan-todo-title">{s.title}</span>
                    {s.detail ? (
                      <span className="gpt-plan-todo-detail" title={s.detail}>
                        {s.detail.length > 120 ? `${s.detail.slice(0, 120)}…` : s.detail}
                      </span>
                    ) : null}
                  </li>
                ))}
              </ul>
            </div>
          );
        default:
          return null;
      }
    });

  return (
    <div className="agent-app gpt-app">
      <header className="agent-header gpt-topbar">
        <div>
          <h1>
            CuteClaw Agent <span className="gpt-version-tag">v0.1.1</span>
          </h1>
        </div>
        <div className="agent-header-actions">
          <ModelPopover
            model={settings?.model ?? ""}
            disabled={!settings}
            extraModels={extraModels}
            onRefresh={refreshModelList}
            onApply={async (m) => {
              const s = await agentApi.putSettings({ model: m });
              setSettings(s);
              setDraftSettings((d) => ({ ...d, model: s.model }));
              setErr(null);
            }}
          />
          <button
            type="button"
            className="agent-btn"
            disabled={!skillDocButtonEnabled}
            title={
              !skillDocButtonEnabled
                ? "请新建 Skill 或从左侧选择已有技能并加载文档"
                : "查看或编辑当前技能的 Markdown（可新建）"
            }
            onClick={() => {
              if (skillSel) openSkillDrawer(skillSel, skillDocMode);
              else setSkillDrawerOpen(true);
            }}
          >
            Skill 文档
          </button>
          <button
            type="button"
            className="agent-btn ghost"
            title="通过 HTTP 提交提议；合并权威实现为 Zig：cuteclaw evolve"
            onClick={() => setEvolveOpen(true)}
          >
            Evolve
          </button>
        </div>
      </header>

      {err && (
        <div className="agent-banner err">
          {err}
          <button type="button" className="agent-dismiss" onClick={() => setErr(null)}>
            ×
          </button>
        </div>
      )}

      <div className="agent-main">
        <aside className="agent-sidebar gpt-sidebar-column">
          <div className="gpt-sidebar-scroll gpt-sidebar-zones">
            <div className={`gpt-sidebar-zone${zoneProjectsOpen ? "" : " is-collapsed"}`}>
              <button
                type="button"
                className="gpt-zone-header"
                onClick={() => {
                  setZoneProjectsOpen((v) => {
                    const n = !v;
                    persistLsBool(LS_ZONE_PROJECTS, n);
                    return n;
                  });
                }}
                aria-expanded={zoneProjectsOpen}
              >
                <span className="gpt-zone-chevron" aria-hidden>
                  {zoneProjectsOpen ? "▼" : "▶"}
                </span>
                <span className="gpt-zone-title">项目</span>
              </button>
              {zoneProjectsOpen && (
                <>
                  <ul className="gpt-project-list">
                    {projects.map((p) => {
                      const active = p.id === projectId;
                      const mk = `proj:${p.id}`;
                      const menuOpen = rowMenuId === mk;
                      return (
                        <li key={p.id} className={`gpt-project-row${active ? " active" : ""}`}>
                          <button
                            type="button"
                            className="gpt-project-main"
                            title={p.title && p.title !== p.id ? `${p.title} (${p.id})` : p.id}
                            onClick={() => {
                              if (!active) switchProject(p.id);
                            }}
                          >
                            <img src="/cuteclaw-lobster.svg" alt="" className="gpt-project-lobster" width={20} height={20} />
                            <span className="gpt-project-title">{p.title ?? p.id}</span>
                          </button>
                          <div className="gpt-row-menu-root" data-gpt-row-menu-root>
                            <button
                              type="button"
                              className="gpt-row-kebab"
                              aria-label="更多操作"
                              aria-expanded={menuOpen}
                              aria-haspopup="menu"
                              onClick={(e) => {
                                e.stopPropagation();
                                setRowMenuId(menuOpen ? null : mk);
                              }}
                            >
                              ⋮
                            </button>
                            {menuOpen && (
                              <div
                                className="gpt-row-menu-dropdown"
                                role="menu"
                                onMouseDown={(e) => e.stopPropagation()}
                              >
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item"
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void renameProjectById(p.id);
                                  }}
                                >
                                  修改名称
                                </button>
                                {p.id !== "default" && (
                                  <button
                                    type="button"
                                    role="menuitem"
                                    className="gpt-row-menu-item danger"
                                    onClick={() => {
                                      setRowMenuId(null);
                                      void deleteProjectById(p.id);
                                    }}
                                  >
                                    删除项目
                                  </button>
                                )}
                              </div>
                            )}
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                  <button type="button" className="agent-linkbtn gpt-project-new" onClick={() => void createNewProject()}>
                    + 新建项目
                  </button>
                </>
              )}
            </div>
            <div className={`gpt-sidebar-zone${zoneSkillsOpen ? "" : " is-collapsed"}`}>
              <button
                type="button"
                className="gpt-zone-header"
                onClick={() => {
                  setZoneSkillsOpen((v) => {
                    const n = !v;
                    persistLsBool(LS_ZONE_SKILLS, n);
                    return n;
                  });
                }}
                aria-expanded={zoneSkillsOpen}
              >
                <span className="gpt-zone-chevron" aria-hidden>
                  {zoneSkillsOpen ? "▼" : "▶"}
                </span>
                <span className="gpt-zone-title">Skills ({skills.length})</span>
              </button>
              {zoneSkillsOpen && (
                <>
                  <button type="button" className="agent-linkbtn" onClick={() => openNewSkillDraft()}>
                    + 新建 Skill
                  </button>
                  <ul className="agent-skill-list gpt-skill-row-list">
                    {skills.map((sk) => {
                      const mk = `skill:${sk.id}`;
                      const menuOpen = rowMenuId === mk;
                      return (
                        <li key={sk.id} className="gpt-skill-row">
                          <button
                            type="button"
                            className={skillSel?.id === sk.id ? "active gpt-skill-main" : "gpt-skill-main"}
                            title={[sk.name, sk.id, sk.description?.trim()].filter(Boolean).join(" · ")}
                            onClick={() => openSkillDrawer(sk, "preview")}
                          >
                            {sk.name}
                          </button>
                          <div className="gpt-row-menu-root" data-gpt-row-menu-root>
                            <button
                              type="button"
                              className="gpt-row-kebab"
                              aria-label="更多操作"
                              aria-expanded={menuOpen}
                              aria-haspopup="menu"
                              onClick={(e) => {
                                e.stopPropagation();
                                setRowMenuId(menuOpen ? null : mk);
                              }}
                            >
                              ⋮
                            </button>
                            {menuOpen && (
                              <div
                                className="gpt-row-menu-dropdown"
                                role="menu"
                                onMouseDown={(e) => e.stopPropagation()}
                              >
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item"
                                  onClick={() => {
                                    setRowMenuId(null);
                                    openSkillDrawer(sk, "markdown");
                                  }}
                                >
                                  Markdown 编辑
                                </button>
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item danger"
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void deleteSkillById(sk);
                                  }}
                                >
                                  删除技能
                                </button>
                              </div>
                            )}
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                </>
              )}
            </div>
            <div className={`gpt-sidebar-zone gpt-sidebar-zone-chats${zoneChatsOpen ? "" : " is-collapsed"}`}>
              <button
                type="button"
                className="gpt-zone-header"
                onClick={() => {
                  setZoneChatsOpen((v) => {
                    const n = !v;
                    persistLsBool(LS_ZONE_CHATS, n);
                    return n;
                  });
                }}
                aria-expanded={zoneChatsOpen}
              >
                <span className="gpt-zone-chevron" aria-hidden>
                  {zoneChatsOpen ? "▼" : "▶"}
                </span>
                <span className="gpt-zone-title">对话</span>
              </button>
              {zoneChatsOpen && (
                <>
                  <button
                    type="button"
                    className="agent-linkbtn gpt-new-chat"
                    onClick={() => {
                      ensureDefaultProjectScope();
                      setSessionId(newSessionId());
                      setMessages([]);
                      setRunFlow([]);
                      setEditingLocalId(null);
                    }}
                  >
                    + 新对话
                  </button>
                  <ul className="agent-session-list gpt-session-list">
                    {mergedSessionRows.map((row) => {
                      const onDisk = sessionOnDisk(row.id);
                      const label = row.title?.trim()
                        ? row.title.trim()
                        : row.id === sessionId && !onDisk
                          ? "新对话"
                          : `对话 ${row.id.slice(0, 8)}…`;
                      const sessionTitleHint =
                        row.title?.trim() && row.title.trim() !== row.id
                          ? `${row.title.trim()} — ${row.id}`
                          : row.id;
                      const active = row.id === sessionId;
                      const mk = `sess:${row.id}`;
                      const menuOpen = rowMenuId === mk;
                      return (
                        <li key={row.id} className="gpt-session-row">
                          <button
                            type="button"
                            className={active ? "active gpt-session-main" : "gpt-session-main"}
                            title={sessionTitleHint}
                            onClick={() => {
                              if (active) return;
                              if (!onDisk) return;
                              void loadSession(row.id);
                            }}
                          >
                            <span className="gpt-session-title">{label}</span>
                          </button>
                          <div className="gpt-row-menu-root" data-gpt-row-menu-root>
                            <button
                              type="button"
                              className="gpt-row-kebab"
                              aria-label="更多操作"
                              aria-expanded={menuOpen}
                              aria-haspopup="menu"
                              onClick={(e) => {
                                e.stopPropagation();
                                setRowMenuId(menuOpen ? null : mk);
                              }}
                            >
                              ⋮
                            </button>
                            {menuOpen && (
                              <div
                                className="gpt-row-menu-dropdown"
                                role="menu"
                                onMouseDown={(e) => e.stopPropagation()}
                              >
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item"
                                  disabled={!onDisk}
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void renameSessionRow(row.id);
                                  }}
                                >
                                  重命名
                                </button>
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item"
                                  disabled={!onDisk}
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void moveSessionRow(row.id, -1);
                                  }}
                                >
                                  上移
                                </button>
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item"
                                  disabled={!onDisk}
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void moveSessionRow(row.id, 1);
                                  }}
                                >
                                  下移
                                </button>
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item"
                                  disabled={!onDisk || projects.length < 2}
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void moveSessionToOtherProject(row.id);
                                  }}
                                >
                                  移到其他项目
                                </button>
                                <button
                                  type="button"
                                  role="menuitem"
                                  className="gpt-row-menu-item danger"
                                  onClick={() => {
                                    setRowMenuId(null);
                                    void deleteSessionRow(row.id);
                                  }}
                                >
                                  删除对话
                                </button>
                              </div>
                            )}
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                </>
              )}
            </div>
          </div>
          <div className="gpt-sidebar-footer">
            <button
              type="button"
              className="gpt-footer-icon"
              title={theme === "dark" ? "切换为浅色" : "切换为深色"}
              aria-label={theme === "dark" ? "切换为浅色" : "切换为深色"}
              onClick={() => setTheme((t) => (t === "dark" ? "light" : "dark"))}
            >
              {theme === "dark" ? (
                <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                  <path d="M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10zm0-5l1.8 3.6L18 7l-3.6 1.8L12 12l-1.8-3.6L6 7l3.6-1.8L12 2zM4 13H2v2h2v-2zm18 0h-2v2h2v-2zM11 2v2h2V2h-2zm0 18v2h2v-2h-2zM4.9 4.9L3.5 6.3l1.4 1.4 1.4-1.4-1.4-1.4zm12.8 12.8l-1.4 1.4 1.4 1.4 1.4-1.4-1.4-1.4zM19.1 4.9l-1.4 1.4 1.4 1.4 1.4-1.4-1.4-1.4zM6.3 17.7l-1.4 1.4 1.4 1.4 1.4-1.4-1.4-1.4z" />
                </svg>
              ) : (
                <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                  <path d="M12 3a9 9 0 1 0 9 9c0-.46-.04-.89-.12-1.32a7 7 0 1 1-8.78-8.78A9 9 0 0 0 12 3z" />
                </svg>
              )}
            </button>
            <button
              type="button"
              className="gpt-footer-icon"
              title="设置"
              aria-label="设置"
              onClick={() => setSettingsOpen(true)}
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                <path d="M19.14 12.94c.04-.31.06-.63.06-.94 0-.31-.02-.63-.06-.94l2.03-1.58a.5.5 0 0 0 .12-.64l-1.92-3.32a.5.5 0 0 0-.6-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.5.5 0 0 0-.49-.42h-3.84a.5.5 0 0 0-.49.42l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96a.5.5 0 0 0-.6.22L2.74 8.87a.5.5 0 0 0 .12.64l2.03 1.58c-.04.31-.06.63-.06.94s.02.63.06.94l-2.03 1.58a.5.5 0 0 0-.12.64l1.92 3.32c.13.22.39.31.61.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.27.42.49.42h3.84c.24 0 .44-.18.49-.42l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.09.48 0 .61-.22l1.92-3.32a.5.5 0 0 0-.12-.64l-2.03-1.58zM12 15.5A3.5 3.5 0 1 1 12 8a3.5 3.5 0 0 1 0 7.5z" />
              </svg>
            </button>
            {settings?.showLegacyConsole !== false && (
              <button
                type="button"
                className="gpt-footer-icon"
                title="旧版控制台"
                aria-label="旧版控制台"
                onClick={() => setLegacyOpen(true)}
              >
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
                  <rect x="3" y="4" width="18" height="14" rx="2" />
                  <path d="M6 8h.01M9 8h.01" strokeLinecap="round" />
                  <path d="M6 12h12M6 15h8" />
                </svg>
              </button>
            )}
          </div>
        </aside>

        <section className="agent-chat gpt-chat">
          <div className="gpt-messages-scroll">
            <div className="gpt-messages-inner">
              {messages.length === 0 && (
                <div className="gpt-welcome">
                  <h2 className="gpt-welcome-title">今天我能帮你做什么？</h2>
                  <p className="gpt-welcome-sub">
                    API Key 可在侧栏底部「设置」中填写，或使用配置文件与环境变量。
                  </p>
                  <div className="gpt-welcome-chips">
                    {welcomeSuggestions.map((s) => (
                      <button
                        key={s}
                        type="button"
                        className="gpt-welcome-chip"
                        onClick={() => setInput(s)}
                      >
                        {s}
                      </button>
                    ))}
                  </div>
                </div>
              )}
              {messages.map((m) => {
                const liveAssist =
                  m.role === "assistant" && loading && m.localId === streamingAssistantId;
                const assistFlow =
                  m.role === "assistant"
                    ? liveAssist
                      ? runFlow
                      : (m.agentTrace ?? [])
                    : [];
                const showAgentRail =
                  m.role === "assistant" &&
                  (assistFlow.length > 0 || (liveAssist && loading));
                return (
                  <div key={m.localId} className={`gpt-turn gpt-turn-${m.role}`}>
                    <div className={`gpt-avatar gpt-avatar-${m.role}`} aria-hidden>
                      {m.role === "user" ? (
                        <img src="/avatar-user.png" alt="" className="gpt-avatar-png" width={36} height={36} />
                      ) : (
                        <img src="/avatar-assistant.png" alt="" className="gpt-avatar-png" width={36} height={36} />
                      )}
                    </div>
                    <div className={`gpt-turn-stack gpt-turn-stack-${m.role}`}>
                      <div className="gpt-turn-label">{m.role === "user" ? "你" : "CuteClaw"}</div>
                      <div className="gpt-turn-body">
                        {editingLocalId === m.localId ? (
                          <div className="gpt-edit-block">
                            <textarea
                              className="gpt-edit-textarea"
                              value={editDraft}
                              onChange={(e) => setEditDraft(e.target.value)}
                              rows={6}
                            />
                            <div className="gpt-msg-actions">
                              <button
                                type="button"
                                className="gpt-btn-mini primary"
                                onClick={() => void saveEditMessage()}
                              >
                                保存
                              </button>
                              <button type="button" className="gpt-btn-mini" onClick={cancelEditMessage}>
                                取消
                              </button>
                            </div>
                          </div>
                        ) : m.role === "user" ? (
                          <div className="gpt-user-turn-column">
                            <div className="gpt-user-bubble-exterior">
                              <div className="gpt-user-bubble-surface">
                                <div className="gpt-md gpt-md-user">{m.content}</div>
                              </div>
                              {!loading && (
                                <div className="gpt-bubble-actions-outside gpt-bubble-actions-user-outside">
                                  <button
                                    type="button"
                                    className="gpt-bubble-iconbtn"
                                    title="复制"
                                    aria-label="复制"
                                    onClick={() => void copyPlain(m.content)}
                                  >
                                    <IconCopy />
                                  </button>
                                  <button
                                    type="button"
                                    className="gpt-bubble-iconbtn"
                                    title="编辑"
                                    aria-label="编辑"
                                    onClick={() => startEditMessage(m)}
                                  >
                                    <IconEdit />
                                  </button>
                                  <button
                                    type="button"
                                    className="gpt-bubble-iconbtn danger"
                                    title="删除"
                                    aria-label="删除"
                                    onClick={() => void deleteMessage(m.localId)}
                                  >
                                    <IconTrash />
                                  </button>
                                </div>
                              )}
                            </div>
                          </div>
                        ) : (
                          <div className="gpt-bubble-wrap gpt-bubble-assistant-column">
                            {showAgentRail && (
                              <div className="gpt-cursor-agent-rail">
                                {liveAssist && loading && assistFlow.length === 0 && (
                                  <div className="gpt-run-flow-wait">
                                    <span
                                      className={`gpt-thinking-spinner${
                                        streamDeltaSeen ? " gpt-thinking-spinner-off" : ""
                                      }`}
                                      aria-hidden
                                    />
                                    <span>{streamDeltaSeen ? "正在生成回复…" : "正在连接模型…"}</span>
                                  </div>
                                )}
                                {assistFlow.length > 0 && (
                                  <details
                                    className="gpt-run-flow-panel gpt-run-flow-panel-cursor"
                                    open={liveAssist}
                                  >
                                    <summary className="gpt-run-flow-panel-sum">Agent 执行流</summary>
                                    <div
                                      ref={liveAssist ? runFlowPanelRef : undefined}
                                      className="gpt-run-flow-panel-body"
                                    >
                                      {renderRunFlowList(assistFlow, liveAssist)}
                                    </div>
                                  </details>
                                )}
                              </div>
                            )}
                            <div className="gpt-md gpt-md-assistant" data-color-mode={mdColorMode}>
                              <MarkdownPreview
                                source={m.content || " "}
                                disableCopy={false}
                                wrapperElement={{ "data-color-mode": mdColorMode }}
                              />
                            </div>
                            {!loading && (
                              <div className="gpt-bubble-actions-outside gpt-bubble-actions-assistant-outside">
                                <button
                                  type="button"
                                  className="gpt-bubble-iconbtn"
                                  title="重新生成"
                                  aria-label="重新生成"
                                  onClick={() => void regenerateFromAssistant(m.localId)}
                                >
                                  <IconRegenerate />
                                </button>
                                <button
                                  type="button"
                                  className="gpt-bubble-iconbtn"
                                  title="复制"
                                  aria-label="复制"
                                  disabled={!m.content.trim()}
                                  onClick={() => void copyPlain(m.content)}
                                >
                                  <IconCopy />
                                </button>
                              </div>
                            )}
                          </div>
                        )}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
          <div className="gpt-compose-outer">
            <div className="gpt-compose-inner">
              <div className="gpt-input-row">
                <textarea
                  className="gpt-input"
                  value={input}
                  onChange={(e) => setInput(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      void handleSend();
                    }
                  }}
                  placeholder="输入消息…"
                  rows={1}
                  disabled={loading}
                />
                {loading ? (
                  <button type="button" className="gpt-send gpt-send-stop" onClick={() => abortRef.current?.abort()} title="停止">
                    ■
                  </button>
                ) : (
                  <button type="button" className="gpt-send" onClick={() => void handleSend()} title="发送" aria-label="发送">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                      <path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z" />
                    </svg>
                  </button>
                )}
              </div>
            </div>
          </div>
        </section>
      </div>

      {skillDrawerOpen && (
        <div className="agent-drawer-back" onClick={() => closeSkillDrawer()}>
          <div className="agent-drawer agent-drawer-skill" onClick={(e) => e.stopPropagation()}>
            <h2>
              {isCreatingSkill ? "新建 Skill" : skillSel ? `${skillSel.name}` : "Skill 文档"}
            </h2>
            <p className="agent-skill-drawer-hint">
              {isCreatingSkill
                ? "填写目录名与正文后保存，将创建 SKILL.md 与 claw.json；之后可在左侧列表中选中继续编辑。"
                : "使用「Markdown / 预览」切换编辑与阅读；保存将写入当前项目 cache 下 skills。"}
            </p>
            {isCreatingSkill && (
              <div className="agent-skill-new-fields">
                <label>技能目录名（cache/skills 下文件夹）</label>
                <input
                  value={newSkillFolderId}
                  onChange={(e) => setNewSkillFolderId(e.target.value)}
                  placeholder="例如 my_tool"
                  autoComplete="off"
                  spellCheck={false}
                />
                <label>显示名称（写入 claw.json，可选）</label>
                <input
                  value={newSkillDisplayName}
                  onChange={(e) => setNewSkillDisplayName(e.target.value)}
                  placeholder="默认同目录名"
                  autoComplete="off"
                />
              </div>
            )}
            <div className="agent-editor-toolbar">
              <span className="agent-editor-path" title={skillDocPathLabel}>
                {skillDocPathLabel}
              </span>
              <button
                type="button"
                className="agent-btn primary"
                disabled={
                  fileSaving || (isCreatingSkill ? !newSkillCanSave : !editorRel || !editorDirty)
                }
                onClick={() => void saveSkillFile()}
              >
                {fileSaving ? "保存中…" : isCreatingSkill ? "创建并保存" : "保存到磁盘"}
              </button>
            </div>
            <div className="agent-skill-mode-toggle" role="tablist" aria-label="文档视图">
              <button
                type="button"
                role="tab"
                aria-selected={skillDocMode === "markdown"}
                className={skillDocMode === "markdown" ? "active" : ""}
                onClick={() => setSkillDocMode("markdown")}
              >
                Markdown
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={skillDocMode === "preview"}
                className={skillDocMode === "preview" ? "active" : ""}
                onClick={() => setSkillDocMode("preview")}
              >
                预览
              </button>
            </div>
            <div className="agent-md-editor-wrap agent-md-editor-skill" data-color-mode={mdColorMode}>
              {skillDocMode === "markdown" ? (
                <div className="agent-md-editor-skill-edit" data-color-mode={mdColorMode}>
                  <MDEditor
                    value={editorContent}
                    onChange={(v) => setEditorContent(v ?? "")}
                    height="100%"
                    minHeight={200}
                    visibleDragbar={false}
                    preview="edit"
                    data-color-mode={mdColorMode}
                    highlightEnable={false}
                  />
                </div>
              ) : (
                <div className="agent-md-preview-pane" data-color-mode={mdColorMode}>
                  <MarkdownPreview source={editorContent} wrapperElement={{ "data-color-mode": mdColorMode }} />
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      {settingsOpen && (
        <div className="agent-drawer-back" onClick={() => setSettingsOpen(false)}>
          <div className="agent-drawer" onClick={(e) => e.stopPropagation()}>
            <h2>设置</h2>
            <label>cache 根目录（绝对或相对仓库根）</label>
            <input
              value={draftSettings.cacheRoot ?? ""}
              onChange={(e) => setDraftSettings((d) => ({ ...d, cacheRoot: e.target.value }))}
            />
            <label>skills 子目录</label>
            <input
              value={draftSettings.skillsSubdir ?? "skills"}
              onChange={(e) => setDraftSettings((d) => ({ ...d, skillsSubdir: e.target.value }))}
            />
            <label>memory 子目录</label>
            <input
              value={draftSettings.memorySubdir ?? "memory"}
              onChange={(e) => setDraftSettings((d) => ({ ...d, memorySubdir: e.target.value }))}
            />
            <label>history 子目录</label>
            <input
              value={draftSettings.historySubdir ?? "history"}
              onChange={(e) => setDraftSettings((d) => ({ ...d, historySubdir: e.target.value }))}
            />
            <label>OpenAI 兼容 API Base</label>
            <input
              value={draftSettings.openaiBase ?? ""}
              onChange={(e) => setDraftSettings((d) => ({ ...d, openaiBase: e.target.value }))}
            />
            <label>OpenAI 兼容 API Key</label>
            <input
              type="password"
              autoComplete="off"
              value={settingsApiKeyDraft}
              onChange={(e) => {
                setSettingsApiKeyDraft(e.target.value);
                setSettingsClearApiKey(false);
              }}
              placeholder={
                settings?.hasOpenaiApiKey
                  ? "已保存密钥，留空则本次不修改"
                  : "sk-… 或服务商密钥，保存后写入本机 cache/settings.json"
              }
            />
            <p className="agent-settings-hint">
              {settings?.hasOpenaiApiKey
                ? "当前已通过界面保存过密钥；填写新值可覆盖，或点「清除已保存密钥」后保存以改用配置文件/环境变量。"
                : "未在界面保存时，宿主会依次尝试环境变量 OPENAI_API_KEY 与下方 config.json 中的 api_key_file / api_key_env。"}
            </p>
            {settings?.hasOpenaiApiKey && (
              <button
                type="button"
                className="agent-btn ghost agent-btn-small"
                onClick={() => {
                  setSettingsClearApiKey(true);
                  setSettingsApiKeyDraft("");
                }}
              >
                {settingsClearApiKey ? "已标记清除（点保存生效）" : "清除已保存密钥"}
              </button>
            )}
            {settingsClearApiKey && (
              <p className="agent-settings-hint">保存设置后将删除界面保存的密钥，之后改用配置文件或环境变量。</p>
            )}
            <label>模型</label>
            <ModelPopover
              model={draftSettings.model ?? settings?.model ?? ""}
              extraModels={extraModels}
              onRefresh={refreshModelList}
              onApply={(m) => setDraftSettings((d) => ({ ...d, model: m }))}
            />
            <label>temperature（0–2）</label>
            <input
              type="number"
              min={0}
              max={2}
              step={0.1}
              value={draftSettings.temperature ?? settings?.temperature ?? 1}
              onChange={(e) => {
                const v = Number(e.target.value);
                setDraftSettings((d) => ({ ...d, temperature: Number.isFinite(v) ? v : 1 }));
              }}
            />
            <label>top_p（0–1，OpenAI 兼容核采样）</label>
            <input
              type="number"
              min={0}
              max={1}
              step={0.05}
              value={draftSettings.topP ?? settings?.topP ?? 1}
              onChange={(e) => {
                const v = Number(e.target.value);
                setDraftSettings((d) => ({ ...d, topP: Number.isFinite(v) ? v : 1 }));
              }}
            />
            <label>Agent 工具轮次上限（-1 为尽量多轮，宿主硬上限 512）</label>
            <input
              type="number"
              min={-1}
              max={512}
              step={1}
              value={draftSettings.agentToolMaxRounds ?? settings?.agentToolMaxRounds ?? 8}
              onChange={(e) => {
                const v = parseInt(e.target.value, 10);
                setDraftSettings((d) => ({
                  ...d,
                  agentToolMaxRounds: Number.isFinite(v) ? v : 8,
                }));
              }}
            />
            <p className="agent-settings-hint">
              多数 OpenAI 兼容接口使用 temperature / top_p；不支持时可忽略或在服务商侧报错。工具轮次为 function calling 循环上限。
            </p>
            <label>CuteClaw config.json 路径（未使用上方 API Key 时读密钥）</label>
            <input
              value={draftSettings.cuteclawConfigPath ?? ""}
              onChange={(e) => setDraftSettings((d) => ({ ...d, cuteclawConfigPath: e.target.value }))}
            />
            <label className="agent-check">
              <input
                type="checkbox"
                checked={draftSettings.showLegacyConsole !== false}
                onChange={(e) =>
                  setDraftSettings((d) => ({ ...d, showLegacyConsole: e.target.checked }))
                }
              />
              显示「旧版控制台」入口
            </label>
            <div className="agent-drawer-actions">
              <button type="button" className="agent-btn primary" onClick={() => void saveSettings()}>
                保存
              </button>
              <button type="button" className="agent-btn ghost" onClick={() => setSettingsOpen(false)}>
                取消
              </button>
            </div>
            {settings && (
              <p className="muted" style={{ marginTop: "1rem", fontSize: "0.8rem" }}>
                当前数据根：<code>{settings.cacheRoot}</code>
              </p>
            )}
          </div>
        </div>
      )}

      {legacyOpen && (
        <div className="agent-drawer-back" onClick={() => setLegacyOpen(false)}>
          <div className="agent-modal wide" onClick={(e) => e.stopPropagation()}>
            <button type="button" className="agent-modal-close" onClick={() => setLegacyOpen(false)}>
              ×
            </button>
            <LegacyConsole />
          </div>
        </div>
      )}

      {evolveOpen && <EvolveModal onClose={() => setEvolveOpen(false)} />}
    </div>
  );
}

function EvolveModal({ onClose }: { onClose: () => void }) {
  const [proposal, setProposal] = useState<ProposalJson>({
    skill_name: "new_skill",
    patch_summary: "init",
    new_body: "12345678\n占位正文至少 8 字符",
  });
  const [policy, setPolicy] = useState("auto_append_only");
  const [semver, setSemver] = useState("0.1.0");
  const [out, setOut] = useState<string | null>(null);

  const submit = async () => {
    try {
      const r = await api.evolve(proposal, policy, semver);
      setOut(JSON.stringify(r, null, 2));
    } catch (e) {
      setOut(String(e));
    }
  };

  return (
    <div className="agent-drawer-back" onClick={onClose}>
      <div className="agent-modal" onClick={(e) => e.stopPropagation()}>
        <h2>提交到 CuteClaw evolve</h2>
        <label>skill_name</label>
        <input
          value={proposal.skill_name}
          onChange={(e) => setProposal((p) => ({ ...p, skill_name: e.target.value }))}
        />
        <label>patch_summary</label>
        <input
          value={proposal.patch_summary}
          onChange={(e) => setProposal((p) => ({ ...p, patch_summary: e.target.value }))}
        />
        <label>new_body</label>
        <textarea
          value={proposal.new_body}
          onChange={(e) => setProposal((p) => ({ ...p, new_body: e.target.value }))}
        />
        <label>policy</label>
        <select value={policy} onChange={(e) => setPolicy(e.target.value)}>
          <option value="auto_append_only">auto_append_only</option>
          <option value="dry_run">dry_run</option>
          <option value="require_human">require_human</option>
        </select>
        <label>semver</label>
        <input value={semver} onChange={(e) => setSemver(e.target.value)} />
        <div className="agent-drawer-actions">
          <button type="button" className="agent-btn primary" onClick={() => void submit()}>
            提交
          </button>
          <button type="button" className="agent-btn ghost" onClick={onClose}>
            关闭
          </button>
        </div>
        {out && <pre className="agent-preview">{out}</pre>}
      </div>
    </div>
  );
}
