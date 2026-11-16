import { describe, expect, it } from "bun:test";
import { correctedMatch, editDistance, ftsMatch, nearTerms } from "./fts-search.js";

const vocab = (...terms: string[]) => terms.map((term) => ({ term, doc: 1 }));

describe("editDistance", () => {
  it("counts insert, delete, substitute and adjacent swap as one", () => {
    expect(editDistance("espresso", "espresso", 2)).toBe(0);
    expect(editDistance("expresso", "espresso", 2)).toBe(1);
    expect(editDistance("espreso", "espresso", 2)).toBe(1);
    expect(editDistance("esrpesso", "espresso", 2)).toBe(1);
    expect(editDistance("esspreso", "espresso", 2)).toBe(2);
    expect(editDistance("abc", "xyzabc", 2)).toBe(3);
  });
});

describe("nearTerms", () => {
  it("ranks by distance, then by how many memos hold the term, and keeps three", () => {
    const terms = [
      { term: "kalender", doc: 2 },
      { term: "kalenders", doc: 9 },
      { term: "kalendar", doc: 5 },
      { term: "kalende", doc: 1 },
      { term: "milch", doc: 8 },
    ];
    expect(nearTerms("kalendr", terms)).toEqual(["kalenders", "kalendar", "kalender"]);
  });
});

describe("correctedMatch", () => {
  const terms = vocab("espresso", "milch", "kaufen");

  it("replaces only the misspelt word and quotes everything", () => {
    expect(correctedMatch("expresso milch", terms)).toBe('("espresso"*) AND "milch"*');
  });

  it("leaves a query alone that has nothing to correct or cannot be corrected", () => {
    expect(correctedMatch("milch", terms)).toBeNull();
    expect(correctedMatch("mil", terms)).toBeNull();
    expect(correctedMatch("xylophon", terms)).toBeNull();
    expect(correctedMatch("expresso xylophon", terms)).toBeNull();
    expect(correctedMatch("   ", terms)).toBeNull();
  });

  it("never lets input act as MATCH syntax", () => {
    expect(correctedMatch('expresso "x" OR', terms)).toBe('("espresso"*) AND """x"""* AND "OR"*');
  });
});

describe("ftsMatch", () => {
  it("is blank, null without a letter, or quoted prefix terms", () => {
    expect(ftsMatch("  ")).toBeUndefined();
    expect(ftsMatch("... ---")).toBeNull();
    expect(ftsMatch('a "b')).toBe('"a"* """b"*');
  });
});
