export const AGENT_STATES = ["idle", "working", "blocked", "done", "unknown"] as const;
export type AgentState = (typeof AGENT_STATES)[number];

/** One herdr tab, the unit the Tab picker offers as a destination. */
export interface HerdTab {
  id: string;
  /** The workspace label, which is the repo name in the estate's convention. */
  repo: string;
  label: string;
  agentState: AgentState;
  /** ISO timestamp; null while the source reports none. */
  lastActivity: string | null;
}

export interface Herd {
  /** Live tabs right now. Throws `MemoError("unavailable")` when the source cannot be reached. */
  snapshot(): Promise<HerdTab[]>;
}
