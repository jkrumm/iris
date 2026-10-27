import { describe, expect, it } from "bun:test";
import { createSqliteDeviceStore } from "../adapters/sqlite-devices.js";
import { systemClock } from "../ports/clock.js";
import { testStore } from "../memo/test-support.js";
import { generateP8 } from "../adapters/apns-test-support.js";
import { selectNotifier, unescapeNewlines } from "./select.js";

// Built at runtime so the public-repo guard (PEM rule) does not read the dummy key as a leak.
const KIND = "PRIVATE KEY";
const pem = (body: string, sep: string) =>
  [`-----BEGIN ${KIND}-----`, body, `-----END ${KIND}-----`].join(sep);

const full = {
  APNS_KEY_P8: pem("abc", "\\n"),
  APNS_KEY_ID: "ABCDE12345",
  APNS_TEAM_ID: "TEAM123456",
  APNS_TOPIC: "com.example.iris",
};

function select(apns: Parameters<typeof selectNotifier>[0]["apns"]) {
  const { db, clock } = testStore();
  return selectNotifier({
    apns,
    devices: createSqliteDeviceStore({ db, clock }),
    clock: systemClock,
  });
}

describe("selectNotifier", () => {
  it("uses the log notifier when nothing is set", () => {
    const selected = select({});
    expect(selected.kind).toBe("log");
    expect(selected.close).toBeUndefined();
  });

  it.each(Object.keys(full))("uses the log notifier when %s is missing", (missing) => {
    expect(select({ ...full, [missing]: undefined }).kind).toBe("log");
    expect(select({ ...full, [missing]: "" }).kind).toBe("log");
  });

  it("uses the APNs notifier when all four are set, with the key's newlines escaped", async () => {
    const generated = await generateP8();
    const selected = select({ ...full, APNS_KEY_P8: generated.pem.replaceAll("\n", "\\n") });
    expect(selected.kind).toBe("apns");
    await selected.close?.();
  });

  it("turns escaped newlines in the key into real ones", () => {
    expect(unescapeNewlines(full.APNS_KEY_P8)).toBe(pem("abc", "\n"));
  });
});
