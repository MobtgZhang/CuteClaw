/** 对齐 CuteClaw persist.StoreDocumentV1 / docs/format.md */

export type TaskOutcome = "success" | "failed" | "aborted" | "needs_human";

export type AuditResult = "accepted" | "rejected" | "deferred";

export interface EpisodicRecord {
  task_id: string;
  ended_unix: number;
  summary: string;
  outcome: TaskOutcome;
}

export interface SkillRecord {
  name: string;
  version: string;
  preconditions: string;
  prohibitions: string;
  body: string;
}

export interface SemanticFact {
  key: string;
  value: string;
  confidence: number;
}

export interface RollupRecord {
  skill_name: string;
  invocations: number;
  successes: number;
  failures: number;
  last_patch_unix: number;
}

export interface AuditRecord {
  unix_ts: number;
  skill_name: string;
  policy: string;
  result: AuditResult;
  detail: string;
}

export interface WorkingState {
  goal: string;
  constraints: string;
  confirmed_facts: string;
  next_step: string;
}

export interface StoreDocumentV1 {
  schema_version: number;
  library_version: string;
  saved_unix: number;
  episodic: EpisodicRecord[];
  skills: SkillRecord[];
  facts: SemanticFact[];
  rollups: RollupRecord[];
  audit: AuditRecord[];
  tasks_recorded: number;
  tasks_succeeded: number;
  working: WorkingState;
}
