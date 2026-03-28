/**
 * OpenAI tools 定义 + 通过 `cuteclaw agent-tool` 执行（与 src/agent_tool_cli.zig 对齐）。
 */
import { runCuteclaw } from "./cuteclaw.js";

export interface AgentToolContext {
  cacheRoot: string;
  projectId: string;
  skillsSubdir: string;
  memorySubdir: string;
}

const bucketProps = {
  bucket: {
    type: "string",
    enum: ["skills", "memory"],
    description: "skills 或 memory 分区（位于项目 cache 子目录下）",
  },
  rel: {
    type: "string",
    description: "相对于该分区的路径，使用 / 分隔；禁止 .. 与绝对路径",
  },
} as const;

/** 与 Zig 侧工具名一致 */
export const AGENT_TOOLS_OPENAI = [
  {
    type: "function" as const,
    function: {
      name: "env_info",
      description: "当前运行环境：操作系统（linux/macos/windows）、CPU 架构。无文件访问。",
      parameters: { type: "object", properties: {}, additionalProperties: false },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "task_plan",
      description:
        "【规划】在回答前或复杂多步任务中使用：先内心判断是否需拆解；若需要，提交带状态的步骤列表（类似子任务/子 Agent）。可随时再次调用以更新各步 status。简单一问一答则不要调用。",
      parameters: {
        type: "object",
        properties: {
          thought: {
            type: "string",
            description: "一两句：任务是否复杂、为何需要/更新计划。",
          },
          steps: {
            type: "array",
            description: "有序步骤；title 为子任务标题，status 表示进度",
            items: {
              type: "object",
              properties: {
                id: { type: "string", description: "可选稳定 id，便于多次更新同一步" },
                title: { type: "string", description: "步骤标题（一句）" },
                status: {
                  type: "string",
                  enum: ["pending", "in_progress", "done", "cancelled"],
                  description: "pending=未开始 in_progress=进行中 done=完成 cancelled=取消",
                },
                detail: { type: "string", description: "可选补充" },
              },
              required: ["title", "status"],
              additionalProperties: false,
            },
          },
        },
        required: ["steps"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_read",
      description: "读取当前项目 cache 下 skills 或 memory 分区内文本文件（有大小上限）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_write",
      description: "写入或覆盖项目 cache 下 skills/memory 分区内文件（自动创建父目录）。",
      parameters: {
        type: "object",
        properties: {
          ...bucketProps,
          content: { type: "string", description: "文件完整内容（UTF-8）" },
        },
        required: ["bucket", "rel", "content"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_list",
      description: "列出项目 cache 下某 bucket 根目录或子目录下的条目名。",
      parameters: {
        type: "object",
        properties: {
          bucket: bucketProps.bucket,
          rel: {
            type: "string",
            description: "子目录相对路径；空字符串表示 bucket 根目录",
          },
        },
        required: ["bucket"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_stat",
      description: "查看 skills/memory 分区内某路径的文件或目录元数据（类型、大小）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_mkdir",
      description: "在 skills/memory 分区内递归创建目录（路径须安全）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_remove",
      description: "删除 skills/memory 分区内的单个文件（不可删目录）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "text_search",
      description:
        "在单个文本文件内按子串搜索匹配行（skills/memory），返回行号与行内容；可选 ASCII 大小写不敏感。",
      parameters: {
        type: "object",
        properties: {
          ...bucketProps,
          needle: { type: "string", description: "要搜索的子串" },
          max_matches: { type: "integer", description: "最多返回条数，默认 80" },
          case_insensitive: { type: "boolean", description: "仅 ASCII 字符大小写不敏感，默认 false" },
        },
        required: ["bucket", "rel", "needle"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_stat",
      description: "查看 skills/memory 分区内某路径是文件还是目录，以及文件大小（字节）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_mkdir",
      description: "在 skills/memory 分区内创建目录（递归创建父目录）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "file_remove",
      description: "删除 skills/memory 分区内的单个文件（非目录）。",
      parameters: {
        type: "object",
        properties: bucketProps,
        required: ["bucket", "rel"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "text_search",
      description:
        "在单个文本文件内按子串搜索匹配行（skills/memory），返回行号与行内容；needle 为字面量。",
      parameters: {
        type: "object",
        properties: {
          ...bucketProps,
          needle: { type: "string", description: "要搜索的字面量子串" },
          max_matches: { type: "integer", description: "最多返回条数，默认 80" },
          case_insensitive: {
            type: "boolean",
            description: "是否 ASCII 不区分大小写，默认 false",
          },
        },
        required: ["bucket", "rel", "needle"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "web_fetch",
      description: "HTTP GET 获取公开 URL 的正文（禁止 file://、禁止访问本机与常见私网地址）。",
      parameters: {
        type: "object",
        properties: {
          url: { type: "string", description: "http 或 https URL" },
          max_bytes: { type: "integer", description: "最大字节数，默认 524288" },
        },
        required: ["url"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "shell_exec",
      description:
        "在仓库/项目目录下执行 shell 命令（需环境变量 CUTECLAW_AGENT_SHELL=1，否则拒绝）。Linux/macOS 使用 sh -c，Windows 使用 cmd /C。",
      parameters: {
        type: "object",
        properties: {
          command: { type: "string", description: "要执行的命令字符串" },
          timeout_ms: { type: "integer", description: "超时毫秒，默认 60000" },
        },
        required: ["command"],
        additionalProperties: false,
      },
    },
  },
];

export type TaskPlanStep = {
  id: string;
  title: string;
  status: "pending" | "in_progress" | "done" | "cancelled";
  detail?: string;
};

/** 校验并截断，供 SSE plan_update 与工具回传共用 */
export function normalizeTaskPlanSteps(args: Record<string, unknown>): {
  thought?: string;
  steps: TaskPlanStep[];
} {
  const thought =
    typeof args.thought === "string" && args.thought.trim() ? args.thought.trim().slice(0, 2000) : undefined;
  const raw = args.steps;
  if (!Array.isArray(raw)) return { thought, steps: [] };
  const steps: TaskPlanStep[] = [];
  const allowed = new Set(["pending", "in_progress", "done", "cancelled"]);
  for (let i = 0; i < raw.length && steps.length < 48; i++) {
    const x = raw[i];
    if (!x || typeof x !== "object") continue;
    const o = x as Record<string, unknown>;
    const title =
      typeof o.title === "string" && o.title.trim() ? o.title.trim().slice(0, 500) : `步骤 ${steps.length + 1}`;
    const st = typeof o.status === "string" ? o.status : "pending";
    const status = (allowed.has(st) ? st : "pending") as TaskPlanStep["status"];
    const id =
      typeof o.id === "string" && o.id.trim()
        ? o.id.trim().slice(0, 80)
        : `step_${i}_${title.slice(0, 24).replace(/\s+/g, "_")}`;
    const detail =
      typeof o.detail === "string" && o.detail.trim() ? o.detail.trim().slice(0, 4000) : undefined;
    steps.push({ id, title, status, detail });
  }
  return { thought, steps };
}

function parseAgentToolStdout(stdout: string): { ok: boolean; result?: unknown; err?: string } {
  const lines = stdout.trim().split(/\n/).filter(Boolean);
  const line = lines.length ? (lines[lines.length - 1] ?? "").trim() : "";
  if (!line) return { ok: false, err: "empty stdout from cuteclaw agent-tool" };
  try {
    const j = JSON.parse(line) as { ok?: boolean; result?: unknown; err?: string };
    if (j.ok === true) return { ok: true, result: j.result };
    return { ok: false, err: typeof j.err === "string" ? j.err : "tool failed" };
  } catch {
    return { ok: false, err: "invalid JSON from agent-tool" };
  }
}

export async function dispatchAgentTool(
  name: string,
  args: Record<string, unknown>,
  ctx: AgentToolContext,
): Promise<{ ok: true; result: unknown } | { ok: false; err: string }> {
  const allowed = new Set(AGENT_TOOLS_OPENAI.map((t) => t.function.name));
  if (!allowed.has(name)) return { ok: false, err: `unknown tool: ${name}` };

  if (name === "task_plan") {
    const { steps } = normalizeTaskPlanSteps(args);
    if (steps.length === 0) return { ok: false, err: "task_plan needs non-empty steps[]" };
    return { ok: true, result: { accepted: true, step_count: steps.length } };
  }

  const payload = {
    tool: name,
    cache_root: ctx.cacheRoot,
    project: ctx.projectId,
    skills_subdir: ctx.skillsSubdir,
    memory_subdir: ctx.memorySubdir,
    args,
  };

  try {
    const r = await runCuteclaw(["agent-tool"], {
      stdin: JSON.stringify(payload),
      timeoutMs: 120_000,
    });
    if (r.code !== 0) {
      const parsed = parseAgentToolStdout(r.stdout);
      if (!parsed.ok && parsed.err) return { ok: false, err: parsed.err };
      const tail = (r.stderr || "").trim() || `exit ${r.code}`;
      return { ok: false, err: tail };
    }
    const parsed = parseAgentToolStdout(r.stdout);
    if (parsed.ok) return { ok: true, result: parsed.result };
    return { ok: false, err: parsed.err ?? "tool error" };
  } catch (e) {
    return { ok: false, err: String(e) };
  }
}
