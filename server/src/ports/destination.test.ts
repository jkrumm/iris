import { describe, expect, it } from "bun:test";
import { fakeDestination } from "./fakes.js";
import { hasChoice, isDestinationName, registeredDestinations } from "./destination.js";

describe("destination registry helpers", () => {
  it("isDestinationName accepts exactly the three names", () => {
    expect(["hermes", "journal", "herdr"].every(isDestinationName)).toBe(true);
    expect(["Hermes", "", "tab", "constructor"].some(isDestinationName)).toBe(false);
  });

  it("registeredDestinations lists the adapters present, in a stable order", () => {
    expect(registeredDestinations({})).toEqual([]);
    expect(
      registeredDestinations({ journal: fakeDestination(), hermes: fakeDestination() }),
    ).toEqual(["hermes", "journal"]);
  });

  it("hasChoice needs two or more", () => {
    expect([[], ["hermes"], ["hermes", "journal"]].map((r) => hasChoice(r as never))).toEqual([
      false,
      false,
      true,
    ]);
  });
});
