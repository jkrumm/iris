import { describe, expect, it } from "bun:test";
import { deliveredTranscript, parsePrefix } from "./prefix.js";

describe("parsePrefix", () => {
  it.each([
    ["Tagebuch: heute war gut", "journal", "heute war gut"],
    ["Journal. Today was fine", "journal", "Today was fine"],
    ["JOURNAL — notes", "journal", "notes"],
    ["Hermes, mach das bitte", "hermes", "mach das bitte"],
    ["An Hermes: erinnere mich morgen", "hermes", "erinnere mich morgen"],
    ["Okay, an Hermes, bitte ruf den Termin ab", "hermes", "bitte ruf den Termin ab"],
  ] as const)("%j routes to %s and strips to %j", (transcript, destination, stripped) => {
    expect(parsePrefix(transcript)).toMatchObject({ destination, stripped });
  });

  it("folds diacritics, so a mis-heard Tägebuch still matches", () => {
    expect(parsePrefix("Tägebuch heute war gut")).toEqual({
      destination: "journal",
      stripped: "heute war gut",
      words: 1,
    });
  });

  it("takes the word after tab as the tab name", () => {
    expect(parsePrefix("tab server mach weiter")).toEqual({
      destination: "herdr",
      tab: "server",
      stripped: "mach weiter",
      words: 2,
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
      words: 6,
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
    expect(parsePrefix("Tagebuch.")).toEqual({
      destination: "journal",
      stripped: "Tagebuch.",
      words: 1,
    });
  });
});

describe("parsePrefix: multi-word tab names", () => {
  const labels = ["server", "iris server", "Iris-Server-Ops", "Café Bar Ost", "iris"];

  it.each([
    ["tab server mach weiter", "server", "mach weiter", 2],
    ["tab iris server mach weiter", "iris server", "mach weiter", 3],
    ["tab iris server ops mach weiter", "iris server ops", "mach weiter", 4],
    ["Tab Cafe Bar Ost, mach weiter", "Cafe Bar Ost", "mach weiter", 4],
    ["okay tab iris server ops: mach weiter", "iris server ops", "mach weiter", 5],
    ["tab iris-server-ops mach weiter", "iris-server-ops", "mach weiter", 2],
  ] as const)("%j names %j and strips to %j (%d words)", (transcript, tab, stripped, words) => {
    expect(parsePrefix(transcript, labels)).toEqual({ destination: "herdr", tab, stripped, words });
  });

  it("prefers the longest label that matches the leading words", () => {
    expect(parsePrefix("tab iris server ops fix it", labels)?.tab).toBe("iris server ops");
    expect(parsePrefix("tab iris server fix it", labels)?.tab).toBe("iris server");
  });

  it("does not take a longer label that matches only its first words", () => {
    // "iris server" is spoken; the label "iris-server-ops" needs a third word
    expect(parsePrefix("tab iris server fix it", ["iris-server-ops"])).toMatchObject({
      tab: "iris",
      stripped: "server fix it",
      words: 2,
    });
    // only the first word is shared
    expect(parsePrefix("tab iris deploy now", ["iris server ops"])).toMatchObject({
      tab: "iris",
      stripped: "deploy now",
    });
  });

  it("stays at one word without labels or when no label matches", () => {
    expect(parsePrefix("tab iris server fix it")).toMatchObject({ tab: "iris", words: 2 });
    expect(parsePrefix("tab iris server fix it", ["vps", "dotfiles"])).toMatchObject({
      tab: "iris",
      words: 2,
    });
  });

  it("does not run a name on past punctuation", () => {
    expect(parsePrefix("tab iris. server ops is next", ["iris server ops"])).toMatchObject({
      tab: "iris",
      stripped: "server ops is next",
    });
  });

  it("keeps the original transcript when the name is all there is", () => {
    expect(parsePrefix("tab iris server", labels)).toMatchObject({
      tab: "iris server",
      stripped: "tab iris server",
      words: 3,
    });
  });
});

describe("deliveredTranscript", () => {
  const raw = "Tagebuch: heute war gut";

  it("cuts the prefix when a prefix decision exists, also behind a later answer", () => {
    expect(deliveredTranscript({ transcript: raw, decisions: [{ source: "prefix" }] })).toBe(
      "heute war gut",
    );
    expect(
      deliveredTranscript({
        transcript: raw,
        decisions: [{ source: "prefix" }, { source: "answer" }],
      }),
    ).toBe("heute war gut");
  });

  it("leaves the raw text for every other source and for no decision", () => {
    expect(deliveredTranscript({ transcript: raw, decisions: [] })).toBe(raw);
    expect(deliveredTranscript({ transcript: raw, decisions: [{ source: "mode" }] })).toBe(raw);
    expect(deliveredTranscript({ transcript: raw, decisions: [{ source: "decide" }] })).toBe(raw);
  });

  it("cuts exactly the recorded word count, however many words the tab name had", () => {
    const tab = "tab iris server ops mach weiter";
    expect(
      deliveredTranscript({ transcript: tab, decisions: [{ source: "prefix", prefixWords: 4 }] }),
    ).toBe("mach weiter");
    // an act-time park row repeats the source without a count; the counted row still decides
    expect(
      deliveredTranscript({
        transcript: tab,
        decisions: [
          { source: "prefix", prefixWords: 4 },
          { source: "prefix" },
          { source: "answer" },
        ],
      }),
    ).toBe("mach weiter");
  });

  it("falls back to parsing for a row without a count", () => {
    expect(
      deliveredTranscript({
        transcript: "tab server mach weiter",
        decisions: [{ source: "prefix" }],
      }),
    ).toBe("mach weiter");
  });

  it("keeps the whole text when the count leaves nothing", () => {
    expect(
      deliveredTranscript({
        transcript: "tab iris",
        decisions: [{ source: "prefix", prefixWords: 2 }],
      }),
    ).toBe("tab iris");
  });

  it("returns the raw text when the transcript no longer has a prefix", () => {
    expect(
      deliveredTranscript({ transcript: "kauf Milch", decisions: [{ source: "prefix" }] }),
    ).toBe("kauf Milch");
  });
});
