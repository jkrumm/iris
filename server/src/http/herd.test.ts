import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import { fakeHerd } from "../ports/fakes.js";
import { call, testApp } from "./test-support.js";

describe("GET /v1/herd", () => {
  it("returns the snapshot as {tabs}", async () => {
    const { app, herd } = testApp({
      herdTabs: [
        { id: "w1:t1", repo: "iris", label: "server", agentState: "blocked", lastActivity: null },
        {
          id: "w2:t3",
          repo: "dotfiles",
          label: "wave",
          agentState: "idle",
          lastActivity: "2026-01-01T00:00:00.000Z",
        },
      ],
    });
    const res = await call(app, { path: "/v1/herd" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      tabs: [
        { id: "w1:t1", repo: "iris", label: "server", agentState: "blocked", lastActivity: null },
        {
          id: "w2:t3",
          repo: "dotfiles",
          label: "wave",
          agentState: "idle",
          lastActivity: "2026-01-01T00:00:00.000Z",
        },
      ],
    });
    expect(herd?.calls).toBe(1);
  });

  it("503s when herdr is unreachable", async () => {
    const { app } = testApp({
      herd: fakeHerd({ failWith: new MemoError("unavailable", "herdr: connect failed") }),
    });
    const res = await call(app, { path: "/v1/herd" });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "unavailable", message: "herdr: connect failed" });
  });

  it("503s when herd is not configured", async () => {
    const { app } = testApp({ herd: false });
    const res = await call(app, { path: "/v1/herd" });
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "unavailable" });
  });

  it("401s without a token", async () => {
    const { app } = testApp();
    expect((await call(app, { path: "/v1/herd", headers: {} })).status).toBe(401);
  });
});
