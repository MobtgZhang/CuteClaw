import type { ApiConfigJson } from "@/types/config.v1";
import type { ProposalJson } from "@/types/proposal";
import type { StoreDocumentV1 } from "@/types/store.v1";

async function j<T>(r: Response | Promise<Response>): Promise<T> {
  const res = await r;
  const data = (await res.json()) as T & { error?: string };
  if (!res.ok) {
    throw new Error((data as { error?: string }).error ?? res.statusText);
  }
  return data as T;
}

export interface HealthResponse {
  ok: boolean;
  cuteclawRoot: string;
  bin: string;
  store: string;
  config: string;
}

export const api = {
  health: () => j<HealthResponse>(fetch("/api/health")),
  status: () => j<{ parsed: Record<string, unknown>; stdout: string }>(fetch("/api/status")),
  getStore: () => j<StoreDocumentV1>(fetch("/api/store")),
  configShow: () => j<{ stdout: string }>(fetch("/api/config-show")),
  getConfig: () => j<ApiConfigJson>(fetch("/api/config")),
  putConfig: (cfg: ApiConfigJson) =>
    j<{ ok: boolean }>(
      fetch("/api/config", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(cfg),
      }),
    ),
  evolve: (proposal: ProposalJson, policy: string, semver: string) =>
    j<{ ok?: boolean; stdout?: string; error?: string }>(
      fetch("/api/evolve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ proposal, policy, semver }),
      }),
    ),
  validate: (proposal: ProposalJson) =>
    fetch("/api/validate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ proposal }),
    }).then(async (r) => {
      const data = (await r.json()) as {
        ok: boolean;
        code: number | null;
        stdout: string;
        stderr: string;
      };
      return { ...data, okHttp: r.ok };
    }),
  task: (taskId: string, outcome: string, summary: string) =>
    j<{ ok: boolean }>(
      fetch("/api/task", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ taskId, outcome, summary }),
      }),
    ),
  invoke: (skill: string, ok: boolean) =>
    j<{ ok: boolean }>(
      fetch("/api/invoke", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ skill, ok }),
      }),
    ),
};
