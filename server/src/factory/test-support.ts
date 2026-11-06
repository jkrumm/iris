import type { FactoryAsk } from "../ports/factory.js";

/** An open decision ask of Issue 113, the one the owner answers and the one pushed. */
export const decisionAsk = (patch: Partial<FactoryAsk> = {}): FactoryAsk => ({
  id: "decision:113:1:ask:0198e5a0-7c1d-7000-8000-000000000001",
  kind: "question",
  source: "decision",
  issue: 113,
  short: "Which cache layer?",
  summary: "The lead needs a call: keep Redis or move to the in-process cache.",
  at: "2026-11-06T09:30:00.000Z",
  stale: false,
  ...patch,
});
