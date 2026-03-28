/** 对齐 evolution.Proposal JSON / docs/format.md */

export interface ProposalJson {
  skill_name: string;
  version_hint?: string;
  patch_summary: string;
  new_body: string;
  preconditions?: string;
  prohibitions?: string;
}
