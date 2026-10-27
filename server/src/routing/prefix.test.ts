import { describe, expect, it } from "bun:test";
import { parsePrefix } from "./prefix.js";

describe("parsePrefix", () => {
  it.each([
    ["Tagebuch: heute war gut", "journal", "heute war gut"],
    ["Journal. Today was fine", "journal", "Today was fine"],
    ["JOURNAL — notes", "journal", "notes"],
    ["Hermes, mach das bitte", "hermes", "mach das bitte"],
    ["An Hermes: erinnere mich morgen", "hermes", "erinnere mich morgen"],
    ["Okay, an Hermes, bitte ruf den Termin ab", "hermes", "bitte ruf den Termin ab"],
  ] as const)("%j routes to %s and strips to %j", (transcript, destination, stripped) => {
    expect(parsePrefix(transcript)).toEqual({ destination, stripped });
  });

  it("folds diacritics, so a mis-heard Tägebuch still matches", () => {
    expect(parsePrefix("Tägebuch heute war gut")).toEqual({
      destination: "journal",
      stripped: "heute war gut",
    });
  });

  it("takes the word after tab as the tab name", () => {
    expect(parsePrefix("tab server mach weiter")).toEqual({
      destination: "herdr",
      tab: "server",
      stripped: "mach weiter",
    });
    expect(parsePrefix("Tab Server, mach weiter")).toMatchObject({ tab: "Server" });
  });

  it("matches the longest phrase at a start position: 'an hermes' strips the 'an'", () => {
    expect(parsePrefix("an hermes bitte")?.stripped).toBe("bitte");
  });

  it("matches a phrase that starts at the sixth word but not the seventh", () => {
    expect(parsePrefix("eins zwei drei vier fünf journal danach")).toEqual({
      destination: "journal",
      stripped: "danach",
    });
    expect(parsePrefix("eins zwei drei vier fünf sechs journal danach")).toBeNull();
  });

  it("does not match inside a longer word", () => {
    expect(parsePrefix("Hermesstraße ist gesperrt")).toBeNull();
    expect(parsePrefix("Das Tabellenblatt fehlt")).toBeNull();
  });

  it("needs a name after tab", () => {
    expect(parsePrefix("tab")).toBeNull();
    expect(parsePrefix("tab ...")).toBeNull();
  });

  it("returns null for plain speech and empty input", () => {
    expect(parsePrefix("kauf bitte Milch")).toBeNull();
    expect(parsePrefix("")).toBeNull();
    expect(parsePrefix("   ")).toBeNull();
  });

  it("keeps the original transcript when the prefix is all there is", () => {
    expect(parsePrefix("Tagebuch.")).toEqual({ destination: "journal", stripped: "Tagebuch." });
  });
});
