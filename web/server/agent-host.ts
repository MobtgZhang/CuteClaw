/**
 * Agent 宿主：./cache 目录 API、Skill 扫描、SSE 聊天（OpenAI 兼容）。
 * 监听 127.0.0.1:8790；仅本地使用。
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Fastify from "fastify";
import cors from "@fastify/cors";
import {
  AGENT_TOOLS_OPENAI,
  dispatchAgentTool,
  normalizeTaskPlanSteps,
  type AgentToolContext,
} from "./agent-tools.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
/** 仓库根（web/server → ../..） */
export const REPO_ROOT = path.resolve(__dirname, "../..");

const DEFAULT_CACHE = path.join(REPO_ROOT, "cache");
const ALLOWED_EXT = new Set([".md", ".json", ".yaml", ".yml", ".toml"]);
const MAX_TREE_DEPTH = 4;
const MAX_FILE_BYTES = 512 * 1024;
const MAX_SESSION_LINES = 2000;
const MAX_SESSION_BODY = 512 * 1024;
const MAX_AGENT_TRACE_ITEMS = 400;
const MAX_AGENT_TRACE_JSON_CHARS = 420_000;
const SESSION_MANIFEST_FILE = "_manifest.json";
/** agentToolMaxRounds === -1 时的实际上限，防止死循环耗尽资源 */
const AGENT_TOOL_ROUNDS_UNLIMITED_CAP = 512;

interface SessionManifest {
  order: string[];
  titles: Record<string, string>;
}

function defaultSessionManifest(): SessionManifest {
  return { order: [], titles: {} };
}

async function readSessionManifest(dir: string): Promise<SessionManifest> {
  const p = path.join(dir, SESSION_MANIFEST_FILE);
  try {
    const raw = await fs.promises.readFile(p, "utf8");
    const j = JSON.parse(raw) as Partial<SessionManifest>;
    return {
      order: Array.isArray(j.order) ? j.order.filter((x) => typeof x === "string") : [],
      titles: j.titles && typeof j.titles === "object" && !Array.isArray(j.titles) ? { ...j.titles } : {},
    };
  } catch {
    return defaultSessionManifest();
  }
}

async function writeSessionManifest(dir: string, m: SessionManifest): Promise<void> {
  const p = path.join(dir, SESSION_MANIFEST_FILE);
  await fs.promises.writeFile(p, JSON.stringify(m, null, 2) + "\n", "utf8");
}

function listSessionIdsFromDir(files: string[]): string[] {
  return files
    .filter((f) => f.endsWith(".jsonl") && f !== SESSION_MANIFEST_FILE)
    .map((f) => f.replace(/\.jsonl$/, ""));
}

function buildOrderedSessions(ids: string[], manifest: SessionManifest): { id: string; title?: string }[] {
  const set = new Set(ids);
  const ordered: string[] = [];
  for (const id of manifest.order) {
    if (set.has(id)) ordered.push(id);
  }
  const rest = ids.filter((id) => !ordered.includes(id)).sort();
  const final = [...ordered, ...rest];
  return final.map((id) => {
    const t = manifest.titles[id];
    return { id, title: typeof t === "string" && t.trim() ? t.trim() : undefined };
  });
}

const PORT = Number(process.env.CUTECLAW_AGENT_PORT ?? "8790");
const HOST = "127.0.0.1";

export interface AgentSettingsFile {
  cacheRoot: string;
  skillsSubdir: string;
  memorySubdir: string;
  historySubdir: string;
  openaiBase: string;
  model: string;
  /** OpenAI 兼容 sampling，默认 1 */
  temperature?: number;
  /** top_p，默认 1 */
  topP?: number;
  /**
   * function calling 最大轮次；8 为内置旧默认；-1 表示尽量多轮（仍有硬上限防挂死）
   */
  agentToolMaxRounds?: number;
  /** 可选：在设置 UI 中保存的 OpenAI 兼容 API Key（写入 settings.json，仅本机） */
  openaiApiKey?: string;
  /** 可选：CuteClaw API config.json 路径（读 api key，当未设置 openaiApiKey 时） */
  cuteclawConfigPath: string;
  showLegacyConsole: boolean;
}

/** 返回给浏览器：永不包含 openaiApiKey 明文 */
function publicSettings(s: AgentSettingsFile) {
  const { openaiApiKey: _k, ...rest } = s;
  return {
    ...rest,
    hasOpenaiApiKey: Boolean(_k && String(_k).trim()),
  };
}

const defaultSettings = (): AgentSettingsFile => ({
  cacheRoot: DEFAULT_CACHE,
  skillsSubdir: "skills",
  memorySubdir: "memory",
  historySubdir: "history",
  openaiBase: "https://api.openai.com/v1",
  model: "gpt-4o",
  temperature: 1,
  topP: 1,
  agentToolMaxRounds: 8,
  cuteclawConfigPath: path.join(REPO_ROOT, ".cuteclaw", "config.json"),
  showLegacyConsole: true,
});

/** 固定位于仓库 cache/settings.json，内含可指向别处的 cacheRoot 字段 */
const SETTINGS_FILE = path.join(DEFAULT_CACHE, "settings.json");

function resolveCacheRoot(raw: string): string {
  if (path.isAbsolute(raw)) return path.normalize(raw);
  return path.resolve(REPO_ROOT, raw);
}

function isInsideRoot(root: string, target: string): boolean {
  const r = path.resolve(root);
  const t = path.resolve(target);
  const rel = path.relative(r, t);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function safeJoinCache(cacheRoot: string, rel: string, subRootName: string): string {
  const subRoot = path.join(cacheRoot, subRootName);
  const joined = path.normalize(path.join(subRoot, rel.replace(/^[/\\]+/, "")));
  if (!isInsideRoot(subRoot, joined)) {
    throw Object.assign(new Error("path_escape"), { statusCode: 403 });
  }
  return joined;
}

const PROJECTS_DIR = "projects";
const PROJECT_META_FILE = "_project.json";

function normalizeProjectId(raw: string | undefined | null): string {
  const d = String(raw ?? "default").trim() || "default";
  return /^[\w.-]+$/.test(d) ? d : "default";
}

function getProjectFromRequest(request: {
  query?: unknown;
  headers?: Record<string, string | string[] | undefined>;
}): string {
  const q = request.query as { project?: string } | undefined;
  if (q && typeof q.project === "string" && q.project.trim()) return normalizeProjectId(q.project);
  const h = request.headers?.["x-project-id"] ?? request.headers?.["X-Project-Id"];
  const hv = Array.isArray(h) ? h[0] : h;
  if (typeof hv === "string" && hv.trim()) return normalizeProjectId(hv);
  return "default";
}

function projectRootsAbs(cacheRoot: string, projectId: string, s: AgentSettingsFile) {
  const base = path.join(cacheRoot, PROJECTS_DIR, projectId);
  return {
    base,
    skillsRoot: path.join(base, s.skillsSubdir),
    memoryRoot: path.join(base, s.memorySubdir),
    sessionsDir: path.join(base, s.historySubdir, "sessions"),
    historyRoot: path.join(base, s.historySubdir),
  };
}

function safeJoinUnder(subRoot: string, rel: string): string {
  const joined = path.normalize(path.join(subRoot, rel.replace(/^[/\\]+/, "")));
  if (!isInsideRoot(subRoot, joined)) {
    throw Object.assign(new Error("path_escape"), { statusCode: 403 });
  }
  return joined;
}

async function ensureProjectDirs(cacheRoot: string, projectId: string, s: AgentSettingsFile): Promise<void> {
  const r = projectRootsAbs(cacheRoot, projectId, s);
  await fs.promises.mkdir(r.skillsRoot, { recursive: true });
  await fs.promises.mkdir(r.memoryRoot, { recursive: true });
  await fs.promises.mkdir(r.sessionsDir, { recursive: true });
}

/** 首次将旧版扁平 cache/skills、memory、history/sessions 迁入 projects/default */
async function migrateLegacyToProjectDefault(cacheRoot: string, s: AgentSettingsFile): Promise<void> {
  const marker = path.join(cacheRoot, PROJECTS_DIR, "default");
  try {
    await fs.promises.access(marker);
    return;
  } catch {
    /* continue migration */
  }
  await fs.promises.mkdir(marker, { recursive: true });
  const roots = projectRootsAbs(cacheRoot, "default", s);
  const legacySkills = path.join(cacheRoot, s.skillsSubdir);
  const legacyMem = path.join(cacheRoot, s.memorySubdir);
  const legacySess = path.join(cacheRoot, s.historySubdir, "sessions");
  try {
    await fs.promises.access(legacySkills);
    await fs.promises.cp(legacySkills, roots.skillsRoot, { recursive: true });
  } catch {
    await fs.promises.mkdir(roots.skillsRoot, { recursive: true });
  }
  try {
    await fs.promises.access(legacyMem);
    await fs.promises.cp(legacyMem, roots.memoryRoot, { recursive: true });
  } catch {
    await fs.promises.mkdir(roots.memoryRoot, { recursive: true });
  }
  try {
    await fs.promises.access(legacySess);
    await fs.promises.mkdir(path.dirname(roots.sessionsDir), { recursive: true });
    await fs.promises.cp(legacySess, roots.sessionsDir, { recursive: true });
  } catch {
    await fs.promises.mkdir(roots.sessionsDir, { recursive: true });
  }
}

async function readOptionalPrompt(rel: string): Promise<string> {
  try {
    return (await fs.promises.readFile(path.join(REPO_ROOT, "prompts", rel), "utf8")).trim();
  } catch {
    return "";
  }
}

async function loadAgentSystemTemplate(skillSummary: string): Promise<string> {
  const caps = await readOptionalPrompt("builtin-host-capabilities.zh.md");
  const p = path.join(REPO_ROOT, "prompts", "agent-system.zh.md");
  try {
    const t = await fs.promises.readFile(p, "utf8");
    let out = t.replace(/\{\{SKILL_SUMMARY\}\}/g, skillSummary);
    if (caps) out += `\n\n---\n\n${caps}`;
    return out;
  } catch {
    const fallback = `你是 CuteClaw 本地 Agent 控制台助手。已识别技能目录中的条目（仅摘要，非完整执行沙箱）：\n${skillSummary}\n回答简洁，可用中文。`;
    return caps ? `${fallback}\n\n---\n\n${caps}` : fallback;
  }
}

async function writeSettingsDisk(s: AgentSettingsFile): Promise<void> {
  await fs.promises.mkdir(DEFAULT_CACHE, { recursive: true });
  const toSave = { ...s, cacheRoot: resolveCacheRoot(s.cacheRoot) };
  await fs.promises.writeFile(SETTINGS_FILE, JSON.stringify(toSave, null, 2) + "\n", "utf8");
}

function normalizeAgentSettingsFile(s: AgentSettingsFile): AgentSettingsFile {
  let temperature = s.temperature;
  if (typeof temperature !== "number" || Number.isNaN(temperature)) temperature = 1;
  temperature = Math.min(2, Math.max(0, temperature));
  let topP = s.topP;
  if (typeof topP !== "number" || Number.isNaN(topP)) topP = 1;
  topP = Math.min(1, Math.max(0, topP));
  let agentToolMaxRounds = s.agentToolMaxRounds;
  if (typeof agentToolMaxRounds !== "number" || !Number.isFinite(agentToolMaxRounds)) agentToolMaxRounds = 8;
  if (agentToolMaxRounds === -1) {
    /* keep */
  } else {
    agentToolMaxRounds = Math.min(AGENT_TOOL_ROUNDS_UNLIMITED_CAP, Math.max(1, Math.floor(agentToolMaxRounds)));
  }
  return { ...s, temperature, topP, agentToolMaxRounds };
}

function effectiveToolRoundLimit(s: AgentSettingsFile): number {
  const v = s.agentToolMaxRounds;
  if (v === -1) return AGENT_TOOL_ROUNDS_UNLIMITED_CAP;
  if (typeof v === "number" && Number.isFinite(v) && v >= 1)
    return Math.min(AGENT_TOOL_ROUNDS_UNLIMITED_CAP, Math.floor(v));
  return 8;
}

async function loadEffectiveSettings(): Promise<AgentSettingsFile> {
  const def = defaultSettings();
  try {
    const raw = await fs.promises.readFile(SETTINGS_FILE, "utf8");
    const j = JSON.parse(raw) as Partial<AgentSettingsFile>;
    return normalizeAgentSettingsFile({
      ...def,
      ...j,
      cacheRoot: resolveCacheRoot(j.cacheRoot ?? def.cacheRoot),
    });
  } catch {
    return normalizeAgentSettingsFile(def);
  }
}

async function ensureCacheLayout(s: AgentSettingsFile): Promise<void> {
  const r = resolveCacheRoot(s.cacheRoot);
  await fs.promises.mkdir(path.join(r, PROJECTS_DIR), { recursive: true });
  await migrateLegacyToProjectDefault(r, s);
  await ensureProjectDirs(r, "default", s);
}

interface TreeNode {
  name: string;
  type: "file" | "dir";
  children?: TreeNode[];
}

async function readTreeDir(dir: string, depth: number): Promise<TreeNode[]> {
  if (depth <= 0) return [];
  const entries = await fs.promises.readdir(dir, { withFileTypes: true });
  const out: TreeNode[] = [];
  for (const e of entries) {
    if (e.name.startsWith(".")) continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      out.push({
        name: e.name,
        type: "dir",
        children: await readTreeDir(full, depth - 1),
      });
    } else if (e.isFile()) {
      out.push({ name: e.name, type: "file" });
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

interface SkillInfo {
  id: string;
  name: string;
  description: string;
  version?: string;
  root: string;
  /** 根目录下单文件 *.md（与文件夹技能并存时，同名文件夹优先） */
  layout?: "folder" | "markdown_file";
}

async function scanSkills(skillsRoot: string): Promise<SkillInfo[]> {
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(skillsRoot, { withFileTypes: true });
  } catch {
    return [];
  }
  const dirNames = new Set(entries.filter((e) => e.isDirectory()).map((e) => e.name));
  const list: SkillInfo[] = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const root = path.join(skillsRoot, e.name);
    let name = e.name;
    let description = "";
    let version: string | undefined;
    const clawPath = path.join(root, "claw.json");
    try {
      const raw = await fs.promises.readFile(clawPath, "utf8");
      const j = JSON.parse(raw) as Record<string, unknown>;
      if (typeof j.name === "string") name = j.name;
      if (typeof j.description === "string") description = j.description;
      if (typeof j.version === "string") version = j.version;
    } catch {
      const skillMd = path.join(root, "SKILL.md");
      try {
        const md = await fs.promises.readFile(skillMd, "utf8");
        const m = md.match(/^#\s+(.+)$/m);
        if (m) name = m[1]!.trim();
        description = md.slice(0, 400);
      } catch {
        /* empty */
      }
    }
    list.push({ id: e.name, name, description, version, root, layout: "folder" });
  }
  for (const e of entries) {
    if (!e.isFile()) continue;
    if (!e.name.toLowerCase().endsWith(".md")) continue;
    const base = e.name.slice(0, -3);
    if (!base || !/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(base)) continue;
    if (dirNames.has(base)) continue;
    const full = path.join(skillsRoot, e.name);
    let name = base;
    let description = "";
    try {
      const md = await fs.promises.readFile(full, "utf8");
      const m = md.match(/^#\s+(.+)$/m);
      if (m) name = m[1]!.trim();
      description = md.slice(0, 400);
    } catch {
      /* skip */
    }
    list.push({ id: base, name, description, root: full, layout: "markdown_file" });
  }
  list.sort((a, b) => a.name.localeCompare(b.name));
  return list;
}

function deriveSessionTitleFromMessages(
  messages: { role?: string; content?: unknown }[],
): string | undefined {
  for (const m of messages) {
    if (m.role !== "user" || typeof m.content !== "string") continue;
    let t = m.content.trim().split("\n")[0] ?? "";
    t = t.replace(/^#+\s*/, "").trim().replace(/\s+/g, " ");
    if (!t) continue;
    return t.length <= 56 ? t : `${t.slice(0, 53)}…`;
  }
  return undefined;
}

async function readApiKey(
  cfgPath: string,
  settingsKey?: string | null,
): Promise<{ key: string | null; base: string; model: string }> {
  let base = "https://api.openai.com/v1";
  let model = "gpt-4o";
  const fromSettings = settingsKey != null && String(settingsKey).trim() !== "" ? String(settingsKey).trim() : "";
  let key: string | null = fromSettings || process.env.OPENAI_API_KEY || null;
  try {
    const raw = await fs.promises.readFile(cfgPath, "utf8");
    const j = JSON.parse(raw) as {
      api_base?: string;
      model?: string;
      api_key_file?: string;
      api_key_env?: string;
    };
    if (j.api_base) base = j.api_base;
    if (j.model) model = j.model;
    if (!fromSettings) {
      if (j.api_key_file) {
        try {
          const k = (await fs.promises.readFile(j.api_key_file, "utf8")).trim();
          if (k) key = k;
        } catch {
          /* */
        }
      }
      if (j.api_key_env && !key) {
        key = process.env[j.api_key_env] ?? null;
      }
    }
  } catch {
    /* no config file */
  }
  return { key, base, model };
}

const app = Fastify({ logger: true });

await app.register(cors, {
  origin: ["http://127.0.0.1:5173", "http://localhost:5173"],
});

app.get("/agent/health", async () => ({ ok: true }));

app.get("/agent/projects", async () => {
  const s = await loadEffectiveSettings();
  const r = resolveCacheRoot(s.cacheRoot);
  await ensureCacheLayout(s);
  const root = path.join(r, PROJECTS_DIR);
  await fs.promises.mkdir(root, { recursive: true });
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(root, { withFileTypes: true });
  } catch {
    return { projects: [{ id: "default", title: "默认项目" }] };
  }
  const projects: { id: string; title?: string }[] = [];
  for (const e of entries) {
    if (!e.isDirectory() || e.name.startsWith(".")) continue;
    if (!/^[\w.-]+$/.test(e.name)) continue;
    let title: string | undefined;
    try {
      const raw = await fs.promises.readFile(path.join(root, e.name, PROJECT_META_FILE), "utf8");
      const j = JSON.parse(raw) as { title?: string };
      if (typeof j.title === "string" && j.title.trim()) title = j.title.trim();
    } catch {
      /* */
    }
    projects.push({ id: e.name, title });
  }
  projects.sort((a, b) => a.id.localeCompare(b.id));
  if (!projects.some((p) => p.id === "default")) {
    await ensureProjectDirs(r, "default", s);
    projects.unshift({ id: "default", title: "默认项目" });
  }
  return { projects };
});

app.post("/agent/projects", async (request, reply) => {
  const body = request.body as { id?: string; title?: string };
  if (!body || typeof body.id !== "string" || !/^[\w.-]+$/.test(body.id)) {
    reply.code(400);
    return { error: "need id (letters, digits, ._-)" };
  }
  const pid = body.id;
  if (pid.startsWith("_")) {
    reply.code(400);
    return { error: "id must not start with underscore" };
  }
  const s = await loadEffectiveSettings();
  const r = resolveCacheRoot(s.cacheRoot);
  await ensureCacheLayout(s);
  const base = path.join(r, PROJECTS_DIR, pid);
  try {
    await fs.promises.access(base);
    reply.code(409);
    return { error: "project exists" };
  } catch {
    /* */
  }
  await ensureProjectDirs(r, pid, s);
  if (typeof body.title === "string" && body.title.trim()) {
    await fs.promises.writeFile(
      path.join(base, PROJECT_META_FILE),
      JSON.stringify({ title: body.title.trim() }, null, 2) + "\n",
      "utf8",
    );
  }
  return { ok: true, id: pid };
});

app.patch("/agent/projects", async (request, reply) => {
  const body = request.body as { id?: string; title?: string };
  if (!body || typeof body.id !== "string" || !/^[\w.-]+$/.test(body.id)) {
    reply.code(400);
    return { error: "need id" };
  }
  const pid = body.id;
  const title =
    typeof body.title === "string" && body.title.trim() ? body.title.trim() : "未命名项目";
  const s = await loadEffectiveSettings();
  const r = resolveCacheRoot(s.cacheRoot);
  await ensureCacheLayout(s);
  const base = path.join(r, PROJECTS_DIR, pid);
  try {
    const st = await fs.promises.stat(base);
    if (!st.isDirectory()) {
      reply.code(400);
      return { error: "not a project directory" };
    }
  } catch {
    reply.code(404);
    return { error: "not found" };
  }
  await fs.promises.writeFile(
    path.join(base, PROJECT_META_FILE),
    JSON.stringify({ title }, null, 2) + "\n",
    "utf8",
  );
  return { ok: true, id: pid, title };
});

app.delete("/agent/projects", async (request, reply) => {
  const q = request.query as { id?: string };
  const raw = q?.id;
  if (!raw || !/^[\w.-]+$/.test(raw) || raw.startsWith("_")) {
    reply.code(400);
    return { error: "bad id" };
  }
  if (raw === "default") {
    reply.code(400);
    return { error: "cannot delete default" };
  }
  const s = await loadEffectiveSettings();
  const r = resolveCacheRoot(s.cacheRoot);
  await ensureCacheLayout(s);
  const base = path.join(r, PROJECTS_DIR, raw);
  try {
    const st = await fs.promises.stat(base);
    if (!st.isDirectory()) {
      reply.code(400);
      return { error: "not a project directory" };
    }
  } catch {
    reply.code(404);
    return { error: "not found" };
  }
  await fs.promises.rm(base, { recursive: true, force: true });
  return { ok: true };
});

app.get("/agent/settings", async () => {
  const s = await loadEffectiveSettings();
  await ensureCacheLayout(s);
  return publicSettings(s);
});

app.put("/agent/settings", async (request, reply) => {
  const body = request.body as Partial<AgentSettingsFile> & { openaiApiKey?: string | null };
  if (!body || typeof body !== "object") {
    reply.code(400);
    return { error: "expected object" };
  }
  const cur = await loadEffectiveSettings();
  const { openaiApiKey: bodyApiKey, ...bodyRest } = body;
  const next: AgentSettingsFile = {
    ...cur,
    ...bodyRest,
    cacheRoot: body.cacheRoot != null ? resolveCacheRoot(String(body.cacheRoot)) : cur.cacheRoot,
  };
  if ("openaiApiKey" in body) {
    if (bodyApiKey === null || bodyApiKey === "") {
      delete next.openaiApiKey;
    } else if (typeof bodyApiKey === "string" && bodyApiKey.trim()) {
      next.openaiApiKey = bodyApiKey.trim();
    }
  } else {
    next.openaiApiKey = cur.openaiApiKey;
  }
  const normalized = normalizeAgentSettingsFile(next);
  await ensureCacheLayout(normalized);
  await writeSettingsDisk(normalized);
  return publicSettings(normalized);
});

function parseOpenAiModelsResponse(raw: unknown): string[] {
  const ids: string[] = [];
  const add = (s: unknown) => {
    if (typeof s === "string" && s.trim()) ids.push(s.trim());
  };
  if (!raw || typeof raw !== "object") return [...new Set(ids)];
  const o = raw as Record<string, unknown>;
  if (Array.isArray(o.data)) {
    for (const x of o.data) {
      if (x && typeof x === "object" && typeof (x as { id?: unknown }).id === "string") add((x as { id: string }).id);
    }
  }
  if (Array.isArray(o.models)) {
    for (const x of o.models) {
      if (typeof x === "string") add(x);
      else if (x && typeof x === "object" && typeof (x as { id?: unknown }).id === "string") add((x as { id: string }).id);
    }
  }
  return [...new Set(ids)];
}

app.get("/agent/openai/models", async (_request, reply) => {
  const s = await loadEffectiveSettings();
  const { key, base: cfgBase } = await readApiKey(s.cuteclawConfigPath, s.openaiApiKey);
  const base = (s.openaiBase && s.openaiBase.trim()) || cfgBase;
  if (!key) {
    reply.code(400);
    return { error: "未配置 API Key，无法拉取模型列表（设置中填写密钥或配置 api_key_file / OPENAI_API_KEY）" };
  }
  const url = `${String(base).replace(/\/$/, "")}/models`;
  try {
    const res = await fetch(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${key}` },
    });
    if (!res.ok) {
      const t = await res.text();
      reply.code(502);
      return { error: `上游返回 ${res.status}`, detail: t.slice(0, 400) };
    }
    const j = (await res.json()) as unknown;
    return { models: parseOpenAiModelsResponse(j) };
  } catch (e) {
    reply.code(502);
    return { error: String(e) };
  }
});

app.get("/agent/tree", async (request, reply) => {
  const q = request.query as { bucket?: string; rel?: string };
  const bucket = q.bucket ?? "skills";
  if (!["skills", "memory", "history"].includes(bucket)) {
    reply.code(400);
    return { error: "bucket must be skills|memory|history" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const rel = (q.rel ?? "").replace(/^[/\\]+/, "");
  const roots = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s);
  const base =
    bucket === "skills" ? roots.skillsRoot : bucket === "memory" ? roots.memoryRoot : roots.historyRoot;
  const target = path.normalize(path.join(base, rel));
  if (!isInsideRoot(base, target)) {
    reply.code(403);
    return { error: "path_escape" };
  }
  try {
    const st = await fs.promises.stat(target);
    if (!st.isDirectory()) {
      reply.code(400);
      return { error: "not_a_directory" };
    }
    const children = await readTreeDir(target, MAX_TREE_DEPTH);
    return { path: rel, bucket, children };
  } catch (e) {
    reply.code(404);
    return { error: String(e) };
  }
});

app.get("/agent/file", async (request, reply) => {
  const q = request.query as { bucket?: string; rel?: string };
  const bucket = q.bucket ?? "skills";
  if (!["skills", "memory", "history"].includes(bucket)) {
    reply.code(400);
    return { error: "bad bucket" };
  }
  const rel = q.rel ?? "";
  if (!rel || rel.includes("..")) {
    reply.code(400);
    return { error: "bad rel" };
  }
  const ext = path.extname(rel).toLowerCase();
  if (!ALLOWED_EXT.has(ext)) {
    reply.code(400);
    return { error: "extension not allowed" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const roots = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s);
  const subRoot = bucket === "skills" ? roots.skillsRoot : bucket === "memory" ? roots.memoryRoot : roots.historyRoot;
  let full: string;
  try {
    full = safeJoinUnder(subRoot, rel);
  } catch {
    reply.code(403);
    return { error: "forbidden" };
  }
  try {
    const buf = await fs.promises.readFile(full);
    if (buf.length > MAX_FILE_BYTES) {
      reply.code(413);
      return { error: "file too large" };
    }
    return { path: rel, content: buf.toString("utf8") };
  } catch {
    reply.code(404);
    return { error: "not found" };
  }
});

app.put("/agent/file", async (request, reply) => {
  const body = request.body as { bucket?: string; rel?: string; content?: unknown; project?: string };
  if (!body || typeof body !== "object") {
    reply.code(400);
    return { error: "expected object" };
  }
  const bucket = body.bucket ?? "skills";
  if (bucket !== "skills" && bucket !== "memory") {
    reply.code(400);
    return { error: "bucket must be skills|memory for write" };
  }
  if (typeof body.content !== "string") {
    reply.code(400);
    return { error: "content must be string" };
  }
  const rel = body.rel ?? "";
  if (!rel || rel.includes("..")) {
    reply.code(400);
    return { error: "bad rel" };
  }
  const ext = path.extname(rel).toLowerCase();
  if (!ALLOWED_EXT.has(ext)) {
    reply.code(400);
    return { error: "extension not allowed" };
  }
  const buf = Buffer.from(body.content, "utf8");
  if (buf.length > MAX_FILE_BYTES) {
    reply.code(413);
    return { error: "content too large" };
  }
  const s = await loadEffectiveSettings();
  const projectId = normalizeProjectId(body.project);
  const roots = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s);
  const subRoot = bucket === "skills" ? roots.skillsRoot : roots.memoryRoot;
  let full: string;
  try {
    full = safeJoinUnder(subRoot, rel);
  } catch {
    reply.code(403);
    return { error: "forbidden" };
  }
  await fs.promises.mkdir(path.dirname(full), { recursive: true });
  await fs.promises.writeFile(full, buf);
  return { ok: true, path: rel };
});

app.get("/agent/skills", async (request) => {
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const roots = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s);
  const skills = await scanSkills(roots.skillsRoot);
  return { skills };
});

app.delete("/agent/skills", async (request, reply) => {
  const q = request.query as { id?: string };
  const raw = q?.id?.trim();
  if (!raw || !/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(raw)) {
    reply.code(400);
    return { error: "bad skill folder id" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const roots = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s);
  let dirPath: string;
  try {
    dirPath = safeJoinUnder(roots.skillsRoot, raw);
  } catch {
    reply.code(403);
    return { error: "forbidden" };
  }
  try {
    const st = await fs.promises.stat(dirPath);
    if (st.isDirectory()) {
      await fs.promises.rm(dirPath, { recursive: true, force: true });
      return { ok: true };
    }
  } catch {
    /* try flat .md */
  }
  let mdPath: string;
  try {
    mdPath = safeJoinUnder(roots.skillsRoot, `${raw}.md`);
  } catch {
    reply.code(403);
    return { error: "forbidden" };
  }
  try {
    const st = await fs.promises.stat(mdPath);
    if (st.isFile()) {
      await fs.promises.unlink(mdPath);
      return { ok: true };
    }
  } catch {
    /* */
  }
  reply.code(404);
  return { error: "not found" };
});

app.post("/agent/history/append", async (request, reply) => {
  const body = request.body as {
    sessionId?: string;
    parentId?: string | null;
    type?: string;
    role?: string;
    payload?: unknown;
    project?: string;
  };
  if (!body?.sessionId || !body?.type) {
    reply.code(400);
    return { error: "need sessionId, type" };
  }
  const s = await loadEffectiveSettings();
  const projectId = normalizeProjectId(body.project);
  const dir = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).sessionsDir;
  await fs.promises.mkdir(dir, { recursive: true });
  const line = JSON.stringify({
    ts: Date.now(),
    sessionId: body.sessionId,
    parentId: body.parentId ?? null,
    type: body.type,
    role: body.role ?? null,
    payload: body.payload ?? null,
  });
  const file = path.join(dir, `${body.sessionId}.jsonl`);
  await fs.promises.appendFile(file, line + "\n", "utf8");
  return { ok: true };
});

app.get("/agent/history/session", async (request, reply) => {
  const q = request.query as { id?: string };
  if (!q.id) {
    reply.code(400);
    return { error: "need id" };
  }
  if (!/^[\w.-]+$/.test(q.id)) {
    reply.code(400);
    return { error: "bad id" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const file = path.join(projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).sessionsDir, `${q.id}.jsonl`);
  try {
    const raw = await fs.promises.readFile(file, "utf8");
    const lines = raw
      .split("\n")
      .filter(Boolean)
      .map((l) => JSON.parse(l) as unknown);
    return { events: lines };
  } catch {
    return { events: [] };
  }
});

function sanitizeAgentTracePayload(raw: unknown): unknown[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const slice = raw.slice(0, MAX_AGENT_TRACE_ITEMS);
  for (const x of slice) {
    if (!x || typeof x !== "object") return undefined;
    const k = (x as { kind?: unknown }).kind;
    if (typeof k !== "string" || k.length === 0 || k.length > 64) return undefined;
  }
  try {
    const s = JSON.stringify(slice);
    if (s.length > MAX_AGENT_TRACE_JSON_CHARS) return undefined;
  } catch {
    return undefined;
  }
  return slice;
}

app.put("/agent/history/session", async (request, reply) => {
  const q = request.query as { id?: string };
  if (!q.id || !/^[\w.-]+$/.test(q.id)) {
    reply.code(400);
    return { error: "bad id" };
  }
  const body = request.body as { messages?: unknown };
  if (!body || typeof body !== "object" || !Array.isArray(body.messages)) {
    reply.code(400);
    return { error: "need messages[]" };
  }
  const messages = body.messages as {
    role?: string;
    content?: unknown;
    agentTrace?: unknown;
  }[];
  if (messages.length > MAX_SESSION_LINES) {
    reply.code(400);
    return { error: "too many messages" };
  }
  const lines: string[] = [];
  const baseTs = Date.now();
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    if (m.role !== "user" && m.role !== "assistant") {
      reply.code(400);
      return { error: "invalid role" };
    }
    if (typeof m.content !== "string") {
      reply.code(400);
      return { error: "invalid content" };
    }
    const type = m.role === "user" ? "user_message" : "assistant_message";
    const payload: Record<string, unknown> = { text: m.content };
    if (m.role === "assistant" && m.agentTrace !== undefined) {
      const tr = sanitizeAgentTracePayload(m.agentTrace);
      if (tr) payload.agentTrace = tr;
    }
    lines.push(
      JSON.stringify({
        ts: baseTs + i,
        sessionId: q.id,
        parentId: null,
        type,
        role: m.role,
        payload,
      }),
    );
  }
  const out = lines.length ? lines.join("\n") + "\n" : "";
  if (Buffer.byteLength(out, "utf8") > MAX_SESSION_BODY) {
    reply.code(413);
    return { error: "session too large" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const dir = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).sessionsDir;
  await fs.promises.mkdir(dir, { recursive: true });
  const file = path.join(dir, `${q.id}.jsonl`);
  await fs.promises.writeFile(file, out, "utf8");
  const manifest = await readSessionManifest(dir);
  const prevTitle = manifest.titles[q.id]?.trim();
  if (!prevTitle) {
    const derived = deriveSessionTitleFromMessages(messages);
    if (derived) manifest.titles[q.id] = derived;
  }
  if (!manifest.order.includes(q.id)) {
    manifest.order = [q.id, ...manifest.order];
  }
  await writeSessionManifest(dir, manifest);
  return { ok: true, count: messages.length };
});

app.delete("/agent/history/session", async (request, reply) => {
  const q = request.query as { id?: string };
  if (!q.id || !/^[\w.-]+$/.test(q.id)) {
    reply.code(400);
    return { error: "bad id" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const dir = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).sessionsDir;
  const file = path.join(dir, `${q.id}.jsonl`);
  try {
    await fs.promises.unlink(file);
  } catch {
    reply.code(404);
    return { error: "not found" };
  }
  const manifest = await readSessionManifest(dir);
  manifest.order = manifest.order.filter((x) => x !== q.id);
  delete manifest.titles[q.id];
  await writeSessionManifest(dir, manifest);
  return { ok: true };
});

app.post("/agent/history/session/move", async (request, reply) => {
  const body = request.body as { id?: string; toProject?: string; fromProject?: string };
  if (!body?.id || !/^[\w.-]+$/.test(body.id)) {
    reply.code(400);
    return { error: "need id" };
  }
  if (!body.toProject || !/^[\w.-]+$/.test(body.toProject) || body.toProject.startsWith("_")) {
    reply.code(400);
    return { error: "bad toProject" };
  }
  const sid = body.id;
  const toP = normalizeProjectId(body.toProject);
  const fromP =
    body.fromProject && /^[\w.-]+$/.test(body.fromProject) && !body.fromProject.startsWith("_")
      ? normalizeProjectId(body.fromProject)
      : getProjectFromRequest(request);
  if (fromP === toP) {
    reply.code(400);
    return { error: "same project" };
  }
  const s = await loadEffectiveSettings();
  const r = resolveCacheRoot(s.cacheRoot);
  await ensureCacheLayout(s);
  await ensureProjectDirs(r, fromP, s);
  await ensureProjectDirs(r, toP, s);
  const srcDir = projectRootsAbs(r, fromP, s).sessionsDir;
  const dstDir = projectRootsAbs(r, toP, s).sessionsDir;
  const srcFile = path.join(srcDir, `${sid}.jsonl`);
  const dstFile = path.join(dstDir, `${sid}.jsonl`);
  try {
    await fs.promises.access(srcFile);
  } catch {
    reply.code(404);
    return { error: "not found" };
  }
  try {
    await fs.promises.access(dstFile);
    reply.code(409);
    return { error: "session exists in target project" };
  } catch {
    /* no conflict */
  }
  const srcMan = await readSessionManifest(srcDir);
  const movedTitle = srcMan.titles[sid];
  await fs.promises.rename(srcFile, dstFile);
  srcMan.order = srcMan.order.filter((x) => x !== sid);
  delete srcMan.titles[sid];
  await writeSessionManifest(srcDir, srcMan);
  const dstMan = await readSessionManifest(dstDir);
  if (!dstMan.order.includes(sid)) dstMan.order.push(sid);
  if (typeof movedTitle === "string" && movedTitle.trim()) dstMan.titles[sid] = movedTitle.trim();
  await writeSessionManifest(dstDir, dstMan);
  return { ok: true };
});

app.patch("/agent/history/sessions", async (request, reply) => {
  const body = request.body as { order?: unknown; titles?: unknown };
  if (!body || typeof body !== "object") {
    reply.code(400);
    return { error: "expected object" };
  }
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const dir = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).sessionsDir;
  await fs.promises.mkdir(dir, { recursive: true });
  let files: string[];
  try {
    files = await fs.promises.readdir(dir);
  } catch {
    files = [];
  }
  const ids = listSessionIdsFromDir(files);
  const idSet = new Set(ids);
  let manifest = await readSessionManifest(dir);

  if (body.titles != null && typeof body.titles === "object" && !Array.isArray(body.titles)) {
    for (const [k, v] of Object.entries(body.titles as Record<string, unknown>)) {
      if (!/^[\w.-]+$/.test(k) || !idSet.has(k)) continue;
      if (typeof v !== "string") continue;
      const t = v.trim();
      if (t) manifest.titles[k] = t;
      else delete manifest.titles[k];
    }
  }

  if (Array.isArray(body.order)) {
    const seen = new Set<string>();
    const next: string[] = [];
    for (const id of body.order) {
      if (typeof id !== "string" || !/^[\w.-]+$/.test(id) || !idSet.has(id) || seen.has(id)) continue;
      seen.add(id);
      next.push(id);
    }
    for (const id of [...ids].sort()) {
      if (!seen.has(id)) next.push(id);
    }
    manifest.order = next;
  }

  await writeSessionManifest(dir, manifest);
  const sessions = buildOrderedSessions(ids, manifest);
  return { ok: true, sessionIds: sessions.map((x) => x.id), sessions };
});

app.get("/agent/history/sessions", async (request) => {
  const s = await loadEffectiveSettings();
  const projectId = getProjectFromRequest(request);
  const dir = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).sessionsDir;
  try {
    const files = await fs.promises.readdir(dir);
    const ids = listSessionIdsFromDir(files);
    const manifest = await readSessionManifest(dir);
    const sessions = buildOrderedSessions(ids, manifest);
    return { sessionIds: sessions.map((x) => x.id), sessions };
  } catch {
    return { sessionIds: [], sessions: [] };
  }
});

interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

type StreamToolCallPart = {
  index?: number;
  id?: string;
  type?: string;
  function?: { name?: string; arguments?: string };
};

/** 流式请求 + 可选多轮 tool_calls，通过 cuteclaw agent-tool 执行 */
async function streamOpenAiChatWithTools(
  url: string,
  key: string,
  model: string,
  apiMessages: Record<string, unknown>[],
  send: (event: string, data: unknown) => void,
  toolCtx: AgentToolContext,
  sampling: { temperature: number; topP: number },
  maxToolRounds: number,
): Promise<void> {
  const dec = new TextDecoder();

  for (let round = 0; round < maxToolRounds; round++) {
    let assistantContent = "";
    const toolAcc = new Map<number, { id: string; name: string; arguments: string }>();

    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model,
        messages: apiMessages,
        stream: true,
        tools: AGENT_TOOLS_OPENAI,
        tool_choice: "auto",
        temperature: sampling.temperature,
        top_p: sampling.topP,
      }),
    });

    if (!res.ok) {
      const t = await res.text();
      send("error", { message: `upstream ${res.status}`, detail: t.slice(0, 500) });
      return;
    }

    const reader = res.body?.getReader();
    if (!reader) {
      send("error", { message: "no response body" });
      return;
    }

    let buf = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split("\n");
      buf = lines.pop() ?? "";
      for (const line of lines) {
        const sline = line.trim();
        if (!sline.startsWith("data:")) continue;
        const data = sline.slice(5).trim();
        if (data === "[DONE]") {
          break;
        }
        try {
          const j = JSON.parse(data) as {
            choices?: Array<{
              delta?: Record<string, unknown> & { content?: string; tool_calls?: StreamToolCallPart[] };
            }>;
          };
          const choice = j.choices?.[0];
          const delta = choice?.delta;
          if (delta && typeof delta === "object") {
            const c = delta.content;
            if (typeof c === "string" && c.length > 0) {
              assistantContent += c;
              send("delta", { text: c });
            }
            for (const key of ["reasoning_content", "reasoning", "thought", "thinking"] as const) {
              const v = delta[key];
              if (typeof v === "string" && v.length > 0) send("thinking", { text: v });
            }
            const tcd = delta.tool_calls;
            if (Array.isArray(tcd)) {
              for (const tc of tcd as StreamToolCallPart[]) {
                const idx = typeof tc.index === "number" ? tc.index : 0;
                const cur = toolAcc.get(idx) ?? { id: "", name: "", arguments: "" };
                if (typeof tc.id === "string" && tc.id.length > 0) cur.id = tc.id;
                if (tc.function?.name) cur.name = tc.function.name;
                if (tc.function?.arguments) cur.arguments += tc.function.arguments;
                toolAcc.set(idx, cur);
              }
            }
          }
        } catch {
          /* skip */
        }
      }
    }

    const toolCallsSorted = Array.from(toolAcc.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([, v]) => v)
      .filter((v) => v.name.length > 0);

    if (toolCallsSorted.length === 0) {
      apiMessages.push({
        role: "assistant",
        content: assistantContent.length > 0 ? assistantContent : null,
      });
      return;
    }

    const tool_calls = toolCallsSorted.map((e, i) => ({
      id: e.id.length > 0 ? e.id : `call_${round}_${i}`,
      type: "function" as const,
      function: {
        name: e.name,
        arguments: e.arguments.length > 0 ? e.arguments : "{}",
      },
    }));

    apiMessages.push({
      role: "assistant",
      content: assistantContent.length > 0 ? assistantContent : null,
      tool_calls,
    });

    for (const tc of tool_calls) {
      let argsObj: Record<string, unknown> = {};
      try {
        argsObj = JSON.parse(tc.function.arguments || "{}") as Record<string, unknown>;
      } catch {
        argsObj = { _parse_error: true, raw: tc.function.arguments };
      }
      if (tc.function.name === "task_plan") {
        const plan = normalizeTaskPlanSteps(argsObj);
        send("step", {
          kind: "plan_update",
          round,
          thought: plan.thought,
          steps: plan.steps,
        });
      }
      send("step", { kind: "tool_call", round, name: tc.function.name, args: argsObj });
      const out = await dispatchAgentTool(tc.function.name, argsObj, toolCtx);
      send("step", {
        kind: "tool_result",
        round,
        name: tc.function.name,
        ok: out.ok,
        result: out.ok ? out.result : undefined,
        err: out.ok ? undefined : out.err,
      });
      apiMessages.push({
        role: "tool",
        tool_call_id: tc.id,
        content: JSON.stringify(out.ok ? out.result : { err: out.err }),
      });
    }

  }

  send("error", { message: `达到工具调用轮数上限（${maxToolRounds}）` });
}

app.post("/agent/chat", async (request, reply) => {
  const body = request.body as {
    messages?: ChatMessage[];
    sessionId?: string;
    project?: string;
    settingsOverride?: Partial<Pick<AgentSettingsFile, "openaiBase" | "model" | "cuteclawConfigPath">>;
  };
  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    reply.code(400);
    return { error: "need messages[]" };
  }

  const s = await loadEffectiveSettings();
  const projectId = normalizeProjectId(body?.project);
  const cfgPath = body.settingsOverride?.cuteclawConfigPath ?? s.cuteclawConfigPath;
  const { key, base: cfgBase, model: cfgModel } = await readApiKey(cfgPath, s.openaiApiKey);
  const base = body.settingsOverride?.openaiBase ?? s.openaiBase ?? cfgBase;
  const model = body.settingsOverride?.model ?? s.model ?? cfgModel;

  const skillsRoot = projectRootsAbs(resolveCacheRoot(s.cacheRoot), projectId, s).skillsRoot;
  const skillList = await scanSkills(skillsRoot);
  const skillSummary =
    skillList.length === 0
      ? "(无已安装技能；可将 ClawHub 技能放入本项目的 cache/projects/<项目>/skills/)"
      : skillList.map((x) => `- ${x.name}: ${x.description.slice(0, 200)}`).join("\n");

  const systemText = await loadAgentSystemTemplate(skillSummary);
  const systemPreamble: ChatMessage = {
    role: "system",
    content: systemText,
  };

  const outbound = [systemPreamble, ...messages.filter((m) => m.role !== "system")];

  reply.hijack();
  reply.raw.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });

  const send = (event: string, data: unknown) => {
    reply.raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };

  send("step", { kind: "skills_loaded", count: skillList.length });

  if (!key) {
    send("error", {
      message:
        "未配置 API Key：请在界面「设置」中填写 OpenAI API Key，或在 .cuteclaw/config.json 设置 api_key_file / api_key_env，或导出 OPENAI_API_KEY",
    });
    reply.raw.end();
    return;
  }

  send("step", { kind: "request_start", model, base });

  try {
    const url = `${base.replace(/\/$/, "")}/chat/completions`;
    const cacheAbs = resolveCacheRoot(s.cacheRoot);
    const toolCtx: AgentToolContext = {
      cacheRoot: cacheAbs,
      projectId,
      skillsSubdir: s.skillsSubdir,
      memorySubdir: s.memorySubdir,
    };
    const apiMessages: Record<string, unknown>[] = outbound.map((m) => ({
      role: m.role,
      content: m.content,
    }));
    await streamOpenAiChatWithTools(
      url,
      key,
      model,
      apiMessages,
      send,
      toolCtx,
      { temperature: s.temperature ?? 1, topP: s.topP ?? 1 },
      effectiveToolRoundLimit(s),
    );
    send("done", {});
  } catch (e) {
    send("error", { message: String(e) });
  }
  reply.raw.end();
});

try {
  await app.listen({ port: PORT, host: HOST });
  app.log.info(`Agent host http://${HOST}:${PORT}`);
  const boot = defaultSettings();
  await ensureCacheLayout(boot);
  try {
    await fs.promises.access(SETTINGS_FILE);
  } catch {
    await writeSettingsDisk(boot);
  }
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
