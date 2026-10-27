import { describe, expect, it } from "bun:test";
import { captureLogs } from "../memo/test-support.js";
import type { DestinationName } from "../ports/destination.js";
import { fakeDecider, fakeHerd } from "../ports/fakes.js";
import type { HerdTab } from "../ports/herd.js";
import { route, type RouteInput } from "./route.js";

const BOTH: DestinationName[] = ["hermes", "journal"];
const ALL: DestinationName[] = ["hermes", "journal", "herdr"];

const tab = (id: string, repo: string, label: string): HerdTab => ({
  id,
  repo,
  label,
  agentState: "idle",
  lastActivity: null,
});
const HERD = [
  tab("w1:t1", "iris", "server"),
  tab("w1:t2", "iris", "Éins"),
  tab("w2:t1", "dotfiles", "1"),
  tab("w3:t1", "vps", "1"),
];

const input = (overrides: Partial<RouteInput> = {}): RouteInput => ({
  memoId: "memo-1",
  mode: "auto",
  transcript: "kauf bitte Milch",
  destinations: BOTH,
  ...overrides,
});

describe("route: mode", () => {
  it("never routes a chat memo elsewhere by prefix or decide", async () => {
    const decider = fakeDecider({ result: { destination: { choice: "journal", confidence: 1 } } });
    const decision = await route(
      input({ mode: "chat", transcript: "Tagebuch heute war gut", destinations: ALL, decider }),
    );
    expect(decision).toMatchObject({ source: "mode", destination: "hermes", outcome: "routed" });
    expect(decider.calls).toEqual([]);
  });

  it.each([
    ["journal", "journal"],
    ["hermes", "hermes"],
    ["tab", "herdr"],
    ["chat", "hermes"],
  ] as const)("mode %s routes to %s without asking anyone", async (mode, destination) => {
    const decider = fakeDecider();
    const herd = fakeHerd({ tabs: [tab("w1:t1", "iris", "server")] });
    const decision = await route(input({ mode, destinations: ALL, decider, herd }));
    expect(decision).toMatchObject({
      source: "mode",
      outcome: "routed",
      destination,
      confidence: 1,
      reason: null,
      costUsd: null,
    });
    expect(decider.calls).toEqual([]);
  });

  it("wins over a spoken prefix", async () => {
    const decision = await route(input({ mode: "hermes", transcript: "Tagebuch heute war gut" }));
    expect(decision).toMatchObject({ source: "mode", destination: "hermes" });
  });

  it("parks with a reason when the destination is not registered", async () => {
    const decision = await route(input({ mode: "journal", destinations: ["hermes"] }));
    expect(decision).toMatchObject({
      source: "mode",
      outcome: "needs_route",
      destination: null,
      confidence: null,
      reason: "journal not available",
    });
  });
});

describe("route: prefix", () => {
  it("routes by the spoken prefix", async () => {
    const decider = fakeDecider();
    const decision = await route(input({ transcript: "Tagebuch: heute war gut", decider }));
    expect(decision).toMatchObject({
      source: "prefix",
      outcome: "routed",
      destination: "journal",
      confidence: 1,
    });
    expect(decider.calls).toEqual([]);
  });

  it("resolves a spoken tab label to the tab id", async () => {
    const decision = await route(
      input({
        transcript: "tab server mach weiter",
        destinations: ALL,
        herd: fakeHerd({ tabs: HERD }),
      }),
    );
    expect(decision).toMatchObject({
      source: "prefix",
      outcome: "routed",
      destination: "herdr",
      tab: "w1:t1",
      confidence: 1,
      reason: null,
    });
  });

  it("routes by prefix even with a single registered destination", async () => {
    const decision = await route(
      input({ transcript: "Hermes, mach das", destinations: ["hermes"] }),
    );
    expect(decision).toMatchObject({
      source: "prefix",
      destination: "hermes",
    });
  });

  it("parks on an unregistered prefix destination", async () => {
    const decision = await route(
      input({ transcript: "Tagebuch: heute war gut", destinations: ["hermes"] }),
    );
    expect(decision).toMatchObject({
      source: "prefix",
      outcome: "needs_route",
      destination: null,
      reason: "journal not available",
    });
  });
});

describe("route: default", () => {
  it("routes to the only registered destination without spending", async () => {
    const decider = fakeDecider();
    const decision = await route(input({ destinations: ["hermes"], decider }));
    expect(decision).toMatchObject({
      source: "default",
      outcome: "routed",
      destination: "hermes",
      confidence: 1,
      model: null,
      costUsd: null,
    });
    expect(decider.calls).toEqual([]);
  });
});

describe("route: decide", () => {
  it("parks when no destination is registered at all", async () => {
    expect(await route(input({ destinations: [] }))).toMatchObject({
      source: "default",
      outcome: "needs_route",
      reason: "no destination available",
    });
  });

  it("parks as 'decide unavailable' without a decider", async () => {
    expect(await route(input())).toMatchObject({
      source: "decide",
      outcome: "needs_route",
      destination: null,
      reason: "decide unavailable",
    });
  });

  it("routes at confidence 0.8 and records model, cost and usage", async () => {
    const decider = fakeDecider({
      result: {
        destination: { choice: "journal", confidence: 0.8 },
        model: "m1",
        costUsd: 0.0004,
        usage: { inputTokens: 90 },
      },
    });
    const decision = await route(input({ decider }));
    expect(decision).toMatchObject({
      source: "decide",
      outcome: "routed",
      destination: "journal",
      confidence: 0.8,
      model: "m1",
      costUsd: 0.0004,
      usage: { inputTokens: 90 },
      reason: null,
    });
  });

  it("offers the registered destinations only and no tab question without herdr", async () => {
    const decider = fakeDecider();
    await route(input({ decider, herd: fakeHerd() }));
    const call = decider.calls[0];
    expect(Object.keys(call?.destinations ?? {})).toEqual(["hermes", "journal"]);
    expect(call?.tabs).toBeUndefined();
    expect(call?.state).toBe("kauf bitte Milch");
  });

  it("parks below 0.8, keeping the best guess for the picker", async () => {
    const decider = fakeDecider({
      result: { destination: { choice: "journal", confidence: 0.79 }, model: "m1", costUsd: 0.001 },
    });
    expect(await route(input({ decider }))).toMatchObject({
      outcome: "needs_route",
      destination: "journal",
      confidence: 0.79,
      reason: "low confidence (0.79)",
      costUsd: 0.001,
    });
  });

  it("parks on a refusal, keeping the cost", async () => {
    const decider = fakeDecider({ result: { destination: null, costUsd: 0.002 } });
    expect(await route(input({ decider }))).toMatchObject({
      outcome: "needs_route",
      destination: null,
      reason: "decide refused",
      costUsd: 0.002,
    });
  });

  it("parks when the model names a destination that was not offered", async () => {
    const decider = fakeDecider({
      result: { destination: { choice: "herdr", confidence: 0.99 } },
    });
    expect(await route(input({ decider }))).toMatchObject({
      outcome: "needs_route",
      destination: null,
      reason: 'decide chose unknown destination "herdr"',
    });
  });

  it("lets a decider failure propagate so the step fails and can be retried", async () => {
    const decider = fakeDecider({ failWith: new Error("agw decide timed out after 1800000 ms") });
    await expect(route(input({ decider }))).rejects.toThrow("agw decide timed out");
  });

  it("caps the transcript at 4000 characters in the state", async () => {
    const decider = fakeDecider();
    await route(input({ decider, transcript: "x".repeat(5000) }));
    expect(decider.calls[0]?.state).toHaveLength(4000);
  });
});

describe("route: decide with herdr", () => {
  const tabs = [
    {
      id: "w1:t1",
      repo: "iris",
      label: "server",
      agentState: "working" as const,
      lastActivity: null,
    },
    { id: "w2:t1", repo: "dotfiles", label: "1", agentState: "idle" as const, lastActivity: null },
  ];

  it("adds the herd to the state, asks for a tab and routes on the weaker confidence", async () => {
    const decider = fakeDecider({
      result: {
        destination: { choice: "herdr", confidence: 0.95 },
        tab: { choice: "w1:t1", confidence: 0.85 },
      },
    });
    const decision = await route(input({ destinations: ALL, decider, herd: fakeHerd({ tabs }) }));
    const call = decider.calls[0];
    expect(call?.tabs).toEqual({ "w1:t1": "iris / server", "w2:t1": "dotfiles / 1" });
    expect(call?.state).toContain("- w1:t1: iris / server (working)");
    expect(decision).toMatchObject({
      outcome: "routed",
      destination: "herdr",
      tab: "w1:t1",
      confidence: 0.85,
    });
  });

  it("parks on a low tab confidence", async () => {
    const decider = fakeDecider({
      result: {
        destination: { choice: "herdr", confidence: 0.95 },
        tab: { choice: "w1:t1", confidence: 0.5 },
      },
    });
    expect(
      await route(input({ destinations: ALL, decider, herd: fakeHerd({ tabs }) })),
    ).toMatchObject({
      outcome: "needs_route",
      destination: "herdr",
      tab: "w1:t1",
      confidence: 0.5,
    });
  });

  it("parks when herdr is chosen without a live tab", async () => {
    const decider = fakeDecider({
      result: {
        destination: { choice: "herdr", confidence: 0.95 },
        tab: { choice: "gone:t9", confidence: 0.99 },
      },
    });
    expect(
      await route(input({ destinations: ALL, decider, herd: fakeHerd({ tabs }) })),
    ).toMatchObject({
      outcome: "needs_route",
      reason: "herdr chosen without a live tab",
      tab: null,
    });
  });

  it("omits the herd and the tab question when the herd cannot be read", async () => {
    const decider = fakeDecider();
    const { result: decision } = await captureLogs(() =>
      route(
        input({ destinations: ALL, decider, herd: fakeHerd({ failWith: new Error("no socket") }) }),
      ),
    );
    expect(decider.calls[0]?.tabs).toBeUndefined();
    expect(decider.calls[0]?.state).toBe("kauf bitte Milch");
    expect(decision.outcome).toBe("routed");
  });

  it("does not read the herd when herdr is not a choice", async () => {
    const herd = fakeHerd({ tabs });
    await route(input({ decider: fakeDecider(), herd }));
    expect(herd.calls).toBe(0);
  });
});

const spoken = (transcript: string, herd = fakeHerd({ tabs: HERD })) =>
  route(input({ transcript, destinations: ALL, herd }));

const modeTab = (herd: ReturnType<typeof fakeHerd> | undefined) =>
  route(input({ mode: "tab", destinations: ALL, herd }));

describe("route: spoken tab", () => {
  it("matches a tab label ignoring case and diacritics", async () => {
    expect(await spoken("TAB eins bitte")).toMatchObject({ outcome: "routed", tab: "w1:t2" });
  });

  it("matches a workspace label that has exactly one tab", async () => {
    expect(await spoken("tab dotfiles mach das")).toMatchObject({
      outcome: "routed",
      tab: "w2:t1",
    });
  });

  it("parks naming the spoken name when several tabs match", async () => {
    expect(await spoken("tab 1 mach das")).toMatchObject({
      source: "prefix",
      outcome: "needs_route",
      destination: "herdr",
      tab: null,
      confidence: null,
      reason: 'several tabs match "1"',
    });
    expect(await spoken("tab iris mach das")).toMatchObject({
      reason: 'several tabs match "iris"',
    });
  });

  it("parks naming the spoken name when no tab matches", async () => {
    expect(await spoken("tab nirgends mach das")).toMatchObject({
      outcome: "needs_route",
      destination: "herdr",
      reason: 'no tab named "nirgends"',
    });
  });

  it("parks as 'herd unavailable' when the herd fails or is absent", async () => {
    const failing = fakeHerd({ failWith: new Error("socket gone") });
    const { result } = await captureLogs(() => spoken("tab server los", failing));
    expect(result).toMatchObject({ outcome: "needs_route", reason: "herd unavailable" });
    const decision = await route(input({ transcript: "tab server los", destinations: ALL }));
    expect(decision).toMatchObject({ outcome: "needs_route", reason: "herd unavailable" });
  });

  it("logs why the herd was unavailable", async () => {
    const { lines } = await captureLogs(() =>
      spoken("tab server los", fakeHerd({ failWith: new Error("socket gone") })),
    );
    expect(lines).toContainEqual(
      expect.objectContaining({ event: "route.herd_unavailable", error: "socket gone" }),
    );
  });
});

const only = (herd: ReturnType<typeof fakeHerd> | undefined) =>
  route(input({ destinations: ["herdr"], herd }));

describe("route: herdr as the only destination", () => {
  it("routes to the only live tab, like mode tab", async () => {
    const decision = await only(fakeHerd({ tabs: [tab("w1:t1", "iris", "server")] }));
    expect(decision).toMatchObject({
      source: "default",
      outcome: "routed",
      destination: "herdr",
      tab: "w1:t1",
      confidence: 1,
    });
  });

  it("parks with 'which tab?' when there are several, and as 'herd unavailable' without a herd", async () => {
    expect(await only(fakeHerd({ tabs: HERD }))).toMatchObject({
      source: "default",
      outcome: "needs_route",
      destination: "herdr",
      reason: "which tab?",
    });
    expect(await only(undefined)).toMatchObject({ reason: "herd unavailable" });
  });
});

describe("route: mode tab", () => {
  it("routes to the only live tab", async () => {
    const decision = await modeTab(fakeHerd({ tabs: [tab("w1:t1", "iris", "server")] }));
    expect(decision).toMatchObject({ source: "mode", outcome: "routed", tab: "w1:t1" });
  });

  it("parks with 'which tab?' when there are several or none", async () => {
    expect(await modeTab(fakeHerd({ tabs: HERD }))).toMatchObject({
      outcome: "needs_route",
      destination: "herdr",
      reason: "which tab?",
    });
    expect(await modeTab(fakeHerd({ tabs: [] }))).toMatchObject({ reason: "which tab?" });
  });

  it("parks as 'herd unavailable' without a readable herd", async () => {
    expect(await modeTab(undefined)).toMatchObject({ reason: "herd unavailable" });
    const { result } = await captureLogs(() => modeTab(fakeHerd({ failWith: new Error("down") })));
    expect(result).toMatchObject({ reason: "herd unavailable" });
  });
});
