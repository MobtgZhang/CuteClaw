import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import Fastify from "fastify";
import cors from "@fastify/cors";
import {
  defaultStorePath,
  defaultConfigPath,
  cuteclawRoot,
  defaultCuteclawBin,
} from "./paths.js";
import { runCuteclaw, parseStatusText } from "./cuteclaw.js";
import { WriteLock } from "./writeLock.js";

const lock = new WriteLock();

async function atomicWriteJson(filePath: string, obj: unknown): Promise<void> {
  const dir = path.dirname(filePath);
  await fs.promises.mkdir(dir, { recursive: true });
  const tmp = `${filePath}.${process.pid}.tmp`;
  const data = `${JSON.stringify(obj, null, 2)}\n`;
  await fs.promises.writeFile(tmp, data, "utf8");
  await fs.promises.rename(tmp, filePath);
}

const app = Fastify({ logger: true });

await app.register(cors, {
  origin: ["http://127.0.0.1:5173", "http://localhost:5173"],
});

app.get("/api/health", async () => ({
  ok: true,
  cuteclawRoot: cuteclawRoot(),
  bin: defaultCuteclawBin(),
  store: defaultStorePath(),
  config: defaultConfigPath(),
}));

app.get("/api/status", async (request, reply) => {
  try {
    const r = await runCuteclaw(["status"], { timeoutMs: 60_000 });
    if (r.code !== 0) {
      reply.code(502);
      return { error: "cuteclaw status failed", code: r.code, stderr: r.stderr, stdout: r.stdout };
    }
    return { parsed: parseStatusText(r.stdout), stdout: r.stdout };
  } catch (e) {
    reply.code(500);
    return { error: String(e) };
  }
});

app.get("/api/store", async (request, reply) => {
  try {
    const r = await runCuteclaw(["export"], { timeoutMs: 120_000 });
    if (r.code !== 0) {
      reply.code(502);
      return { error: "cuteclaw export failed", code: r.code, stderr: r.stderr };
    }
    const doc = JSON.parse(r.stdout) as unknown;
    return doc;
  } catch (e) {
    reply.code(500);
    return { error: String(e) };
  }
});

app.get("/api/config-show", async (request, reply) => {
  try {
    const r = await runCuteclaw(["config", "show"], { timeoutMs: 30_000 });
    if (r.code !== 0) {
      reply.code(502);
      return { error: "config show failed", code: r.code, stderr: r.stderr, stdout: r.stdout };
    }
    return { stdout: r.stdout };
  } catch (e) {
    reply.code(500);
    return { error: String(e) };
  }
});

app.get("/api/config", async (request, reply) => {
  const p = defaultConfigPath();
  try {
    const raw = await fs.promises.readFile(p, "utf8");
    return JSON.parse(raw) as unknown;
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    if (err.code === "ENOENT") {
      reply.code(404);
      return { error: "config not found", path: p };
    }
    reply.code(500);
    return { error: String(e) };
  }
});

app.put("/api/config", async (request, reply) => {
  const body = request.body as Record<string, unknown>;
  if (!body || typeof body !== "object") {
    reply.code(400);
    return { error: "expected JSON object", code: null };
  }
  const tmp = path.join(os.tmpdir(), `cuteclaw-cfg-val-${Date.now()}.json`);
  try {
    await fs.promises.writeFile(tmp, `${JSON.stringify(body, null, 2)}\n`, "utf8");
    const r = await runCuteclaw(["config", "validate"], {
      timeoutMs: 30_000,
      env: { CUTECLAW_CONFIG: tmp },
    });
    if (r.code !== 0) {
      reply.code(400);
      return {
        error: "config validate failed (与 CLI `config validate` 一致)",
        code: r.code,
        stderr: r.stderr,
        stdout: r.stdout,
      };
    }
    await atomicWriteJson(defaultConfigPath(), body);
    return { ok: true as const };
  } catch (e) {
    reply.code(500);
    return { error: String(e), code: null };
  } finally {
    await fs.promises.unlink(tmp).catch(() => undefined);
  }
});

app.post("/api/evolve", async (request, reply) => {
  const b = request.body as {
    proposal: Record<string, unknown>;
    policy: string;
    semver: string;
  };
  if (!b?.proposal || !b?.policy || !b?.semver) {
    reply.code(400);
    return { error: "need proposal, policy, semver" };
  }
  return lock.run(async () => {
    const tmp = path.join(os.tmpdir(), `cuteclaw-proposal-${Date.now()}.json`);
    try {
      await fs.promises.writeFile(tmp, JSON.stringify(b.proposal, null, 2), "utf8");
      const r = await runCuteclaw(
        ["evolve", "--file", tmp, "--policy", b.policy, "--semver", b.semver],
        { timeoutMs: 120_000 },
      );
      if (r.code !== 0) {
        reply.code(502);
        return { error: "evolve failed", code: r.code, stderr: r.stderr, stdout: r.stdout };
      }
      return { ok: true, stdout: r.stdout };
    } finally {
      await fs.promises.unlink(tmp).catch(() => undefined);
    }
  });
});

app.post("/api/validate", async (request, reply) => {
  const b = request.body as { proposal: Record<string, unknown> };
  if (!b?.proposal) {
    reply.code(400);
    return { error: "need proposal" };
  }
  const tmp = path.join(os.tmpdir(), `cuteclaw-val-${Date.now()}.json`);
  try {
    await fs.promises.writeFile(tmp, JSON.stringify(b.proposal, null, 2), "utf8");
    const r = await runCuteclaw(["validate", "--file", tmp], { timeoutMs: 30_000 });
    return {
      ok: r.code === 0,
      code: r.code,
      stdout: r.stdout,
      stderr: r.stderr,
    };
  } finally {
    await fs.promises.unlink(tmp).catch(() => undefined);
  }
});

app.post("/api/task", async (request, reply) => {
  const b = request.body as { taskId: string; outcome: string; summary: string };
  if (!b?.taskId || !b?.outcome || b.summary === undefined) {
    reply.code(400);
    return { error: "need taskId, outcome, summary" };
  }
  return lock.run(async () => {
    const r = await runCuteclaw(["task", b.taskId, b.outcome, b.summary], {
      timeoutMs: 60_000,
    });
    if (r.code !== 0) {
      reply.code(502);
      return { error: "task failed", code: r.code, stderr: r.stderr, stdout: r.stdout };
    }
    return { ok: true, stdout: r.stdout };
  });
});

app.post("/api/invoke", async (request, reply) => {
  const b = request.body as { skill: string; ok: boolean };
  if (!b?.skill || typeof b.ok !== "boolean") {
    reply.code(400);
    return { error: "need skill, ok (boolean)" };
  }
  return lock.run(async () => {
    const flag = b.ok ? "ok" : "fail";
    const r = await runCuteclaw(["invoke", b.skill, flag], { timeoutMs: 60_000 });
    if (r.code !== 0) {
      reply.code(502);
      return { error: "invoke failed", code: r.code, stderr: r.stderr, stdout: r.stdout };
    }
    return { ok: true, stdout: r.stdout };
  });
});

app.post("/api/import-store", async (request, reply) => {
  const body = request.body;
  if (typeof body !== "object" || body === null) {
    reply.code(400);
    return { error: "expected JSON store document" };
  }
  return lock.run(async () => {
    const r = await runCuteclaw(["import"], {
      stdin: JSON.stringify(body),
      timeoutMs: 120_000,
    });
    if (r.code !== 0) {
      reply.code(502);
      return { error: "import failed", code: r.code, stderr: r.stderr, stdout: r.stdout };
    }
    return { ok: true, stdout: r.stdout };
  });
});

const port = Number(process.env.CUTECLAW_API_PORT ?? "8787");
const host = "127.0.0.1";

try {
  await app.listen({ port, host });
  app.log.info(`CuteClaw API http://${host}:${port}`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
