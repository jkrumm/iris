import { describe, expect, it } from "bun:test";
import { seedMemo, testStore } from "../memo/test-support.js";
import { createLogNotifier } from "./notifier-log.js";

describe("log notifier", () => {
  it("logs the memo id, device, headline and detail only", async () => {
    const { store } = testStore();
    const memo = seedMemo(store, "summarized", "iphone");
    const lines: { event: string; fields: Record<string, unknown> }[] = [];
    const notifier = createLogNotifier({
      logger: (event, fields) => lines.push({ event, fields: fields ?? {} }),
    });

    await notifier.notify({
      memo: { ...memo, transcript: "secret transcript text" },
      summary: { headline: "Milk", detail: "Buy milk tomorrow", spoken: "Remember the milk." },
    });

    expect(lines).toEqual([
      {
        event: "notify.log",
        fields: {
          memo_id: memo.id,
          device: "iphone",
          headline: "Milk",
          detail: "Buy milk tomorrow",
        },
      },
    ]);
  });

  it("logs nothing for a phase change", async () => {
    const { store } = testStore();
    const lines: string[] = [];
    const notifier = createLogNotifier({ logger: (event) => lines.push(event) });
    await notifier.phase({ memo: seedMemo(store, "acted") });
    expect(lines).toEqual([]);
  });
});
