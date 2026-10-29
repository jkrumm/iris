import { describe, expect, it } from "bun:test";
import { Env } from "./env.js";

const parse = (AUDIO_DOOR_URL: string) => Env.safeParse({ AUDIO_DOOR_URL });

describe("AUDIO_DOOR_URL", () => {
  it.each([
    "http://127.0.0.1:7792/v1",
    "http://localhost:7792/v1",
    "http://[::1]:7792/v1",
    "https://door.example.com/v1",
  ])("accepts %s", (url) => {
    const result = parse(url);
    expect(result.success).toBe(true);
    expect(result.data?.AUDIO_DOOR_URL).toBe(url);
  });

  it.each([
    "http://door.example.com/v1",
    "http://192.0.2.10:7792/v1",
    "http://127.0.0.1.example.com/v1",
  ])("refuses plain http to %s with a clear message", (url) => {
    const result = parse(url);
    expect(result.success).toBe(false);
    expect(result.error?.issues[0]?.message).toContain("must be https or a loopback host");
  });

  it("refuses a value that is not a URL", () => {
    expect(parse("not a url").success).toBe(false);
  });

  it("treats an empty value as unset", () => {
    const result = parse("");
    expect(result.success).toBe(true);
    expect(result.data?.AUDIO_DOOR_URL).toBeUndefined();
  });
});
