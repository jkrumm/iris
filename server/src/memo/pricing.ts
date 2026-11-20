// The one price table for spend iris-server estimates itself. A downstream that reports its own cost (agw `triage`) is
// never re-priced here; these cover the two that do not: Hermes (it prices its Claude-gateway turns at 0) and the audio door
// (agent-workflows records the call's cost in its own run, not in the answer). An estimate is always marked as one
// (`costEstimated`, span attribute `cost_estimated`), and an unknown model is no cost, never a guess.
//
// Rates are the ones agent-workflows prices the same calls at (`packages/routes/src/table/claude.ts`, verified there against
// Anthropic's pricing page and the org's cost report 2026-11-01; `table/audio.ts` for Voxtral, docs.mistral.ai 2026-10-25).
// Not modelled: the 5x tier of a Haiku request over 100k prompt tokens (Hermes reports per-turn totals, not per call) and the
// 1-hour cache write rate (a cache write is priced as the 5-minute one).

/** USD per million tokens. */
export interface TokenRate {
  inputPerM: number;
  outputPerM: number;
  cacheReadPerM: number;
  cacheWritePerM: number;
}

const MODEL_RATES: Readonly<Record<string, TokenRate>> = {
  "claude-haiku-5-5": {
    inputPerM: 0.1,
    outputPerM: 0.5,
    cacheReadPerM: 0.01,
    cacheWritePerM: 0.125,
  },
  "claude-sonnet-5-5": { inputPerM: 2, outputPerM: 10, cacheReadPerM: 0.1, cacheWritePerM: 2.5 },
  "claude-opus-5-5": { inputPerM: 4, outputPerM: 20, cacheReadPerM: 0.2, cacheWritePerM: 5 },
};

/** Voxtral mini transcription, billed per minute of audio. */
export const STT_USD_PER_MINUTE = 0.0035;

// A dated snapshot (`claude-haiku-5-5-20261001`) or a context flag (`[1m]`) is the same model at the same rate.
const SNAPSHOT_SUFFIX = /(?:-[0-9]{8})?(?:\[1m\])?$/;

export function rateForModel(model: string | null | undefined): TokenRate | undefined {
  if (!model) return undefined;
  return MODEL_RATES[model.replace(SNAPSHOT_SUFFIX, "")];
}

/** Micro-dollars: the table's resolution, and stable under float noise. */
const roundUsd = (usd: number): number => Math.round(usd * 1e6) / 1e6;

/** What transcribing `audioSeconds` of audio costs. */
export function estimateTranscribeCostUsd(audioSeconds: number): number {
  return roundUsd((Math.max(0, audioSeconds) / 60) * STT_USD_PER_MINUTE);
}

export interface TurnTokens {
  /** Hermes counts the whole prompt: cache reads and writes are inside it. */
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number | undefined;
  cacheWriteTokens?: number | undefined;
}

/**
 * What a Hermes turn cost, or undefined for a model with no rate. Without cache counts the whole prompt is priced as
 * uncached input, which over-states a cache-heavy turn: the estimate is an upper bound then.
 */
export function estimateTurnCostUsd(params: {
  model: string | null | undefined;
  tokens: TurnTokens;
}): number | undefined {
  const rate = rateForModel(params.model);
  if (!rate) return undefined;
  const { inputTokens, outputTokens } = params.tokens;
  const cacheRead = params.tokens.cacheReadTokens ?? 0;
  const cacheWrite = params.tokens.cacheWriteTokens ?? 0;
  const uncached = Math.max(0, inputTokens - cacheRead - cacheWrite);
  return roundUsd(
    (uncached * rate.inputPerM +
      cacheRead * rate.cacheReadPerM +
      cacheWrite * rate.cacheWritePerM +
      outputTokens * rate.outputPerM) /
      1e6,
  );
}
