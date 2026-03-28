import { spawn } from "node:child_process";
import fs from "node:fs";
import { defaultCuteclawBin, childEnv } from "./paths.js";

export interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

export function assertBinaryExists(): void {
  const bin = defaultCuteclawBin();
  if (!fs.existsSync(bin)) {
    throw new Error(
      `找不到 cuteclaw 可执行文件: ${bin}\n请在 CuteClaw 目录执行 zig build，或设置 CUTECLAW_BIN`,
    );
  }
}

export function runCuteclaw(
  args: string[],
  options: { stdin?: string; timeoutMs?: number; env?: Record<string, string> } = {},
): Promise<RunResult> {
  assertBinaryExists();
  const bin = defaultCuteclawBin();
  const timeoutMs = options.timeoutMs ?? 120_000;
  const env: NodeJS.ProcessEnv = options.env ? { ...childEnv(), ...options.env } : childEnv();

  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`cuteclaw 超时 (${timeoutMs}ms): ${[bin, ...args].join(" ")}`));
    }, timeoutMs);

    child.stdout?.on("data", (c: Buffer) => {
      stdout += c.toString("utf8");
    });
    child.stderr?.on("data", (c: Buffer) => {
      stderr += c.toString("utf8");
    });

    if (options.stdin !== undefined) {
      child.stdin?.write(options.stdin, "utf8");
      child.stdin?.end();
    } else {
      child.stdin?.end();
    }

    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? null, stdout, stderr });
    });
  });
}

/** 解析 `cuteclaw status` 文本输出 */
export function parseStatusText(text: string): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = { raw: text };
  const store = text.match(/^store:\s*(.+)$/m);
  if (store) out.storePath = store[1]!.trim();

  const cfg = text.match(/^config:\s*(.+)$/m);
  if (cfg) {
    const line = cfg[1]!.trim();
    out.configPath = line.replace(/\s*\([^)]*\)\s*$/, "").trim();
    out.configExists = line.includes("存在");
  }

  const counts = text.match(/episodic:\s*(\d+)\s+skills:\s*(\d+)\s+facts:\s*(\d+)/);
  if (counts) {
    out.episodic = Number(counts[1]);
    out.skills = Number(counts[2]);
    out.facts = Number(counts[3]);
  }

  const tasks = text.match(/tasks_recorded:\s*(\d+)\s+tasks_succeeded:\s*(\d+)/);
  if (tasks) {
    out.tasks_recorded = Number(tasks[1]);
    out.tasks_succeeded = Number(tasks[2]);
  }

  const audit = text.match(/audit_tail:\s*(\d+)\s+rollups:\s*(\d+)/);
  if (audit) {
    out.audit_tail = Number(audit[1]);
    out.rollups = Number(audit[2]);
  }

  return out;
}
