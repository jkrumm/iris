import { describe, expect, it } from "bun:test";
import {
  estimateTranscribeCostUsd,
  estimateTurnCostUsd,
  rateForModel,
  STT_USD_PER_MINUTE,
} from "./pricing.js";

describe("estimateTranscribeCostUsd", () => {
  it("prices audio per minute", () => {
    expect(estimateTranscribeCostUsd(60)).toBe(STT_USD_PER_MINUTE);
    expect(estimateTranscribeCostUsd(90)).toBe(0.00525);
  });

  it("is zero for no audio and never negative", () => {
    expect(estimateTranscribeCostUsd(0)).toBe(0);
    expect(estimateTranscribeCostUsd(-5)).toBe(0);
  });
});

describe("estimateTurnCostUsd", () => {
  const model = "claude-haiku-5-5";

  it("prices uncached input, cache reads, cache writes and output at their own rates", () => {
    // 1M prompt: 600k read, 100k written, 300k uncached; 200k output.
    const cost = estimateTurnCostUsd({
      model,
      tokens: {
        inputTokens: 1_000_000,
        outputTokens: 200_000,
        cacheReadTokens: 600_000,
        cacheWriteTokens: 100_000,
      },
    });
    // 0.3 * 0.1 + 0.6 * 0.01 + 0.1 * 0.125 + 0.2 * 0.5
    expect(cost).toBe(0.1485);
  });

  it("treats the whole prompt as uncached input without cache counts", () => {
    const cost = estimateTurnCostUsd({
      model,
      tokens: { inputTokens: 40_000, outputTokens: 1_000 },
    });
    expect(cost).toBe(0.0045);
  });

  it("never prices a negative uncached remainder", () => {
    const cost = estimateTurnCostUsd({
      model,
      tokens: { inputTokens: 10, outputTokens: 0, cacheReadTokens: 100 },
    });
    expect(cost).toBe(0.000001);
  });

  it("has no cost for an unknown or missing model", () => {
    const tokens = { inputTokens: 10, outputTokens: 5 };
    expect(estimateTurnCostUsd({ model: "gpt-x", tokens })).toBeUndefined();
    expect(estimateTurnCostUsd({ model: null, tokens })).toBeUndefined();
  });
});

describe("rateForModel", () => {
  it("matches a dated snapshot and the context flag to the model's rate", () => {
    const base = rateForModel("claude-sonnet-5-5");
    expect(base).toBeDefined();
    expect(rateForModel("claude-sonnet-5-5-20261001")).toBe(base);
    expect(rateForModel("claude-sonnet-5-5[1m]")).toBe(base);
  });
});
