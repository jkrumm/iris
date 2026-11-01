import { describe, expect, test } from "bun:test";
import {
  type Catalog,
  checkCatalog,
  normalize,
  normalizeLiteral,
  scanSwift,
} from "./check-strings";

const scan = (src: string, inPackage = false) => scanSwift("X.swift", src, inPackage);
const keys = (src: string, inPackage = false) =>
  scan(src, inPackage).map((h) => `${h.kind}:${h.key.replace(/\uE000/g, "%")}`);

describe("scanSwift", () => {
  test("a SwiftUI literal is a catalog key", () => {
    expect(keys(`Text("Hello")\nButton("Save") {}\n.navigationTitle("Title")`)).toEqual([
      "keyed:Hello",
      "keyed:Save",
      "keyed:Title",
    ]);
  });

  test("String(localized:) and LocalizedStringResource are catalog keys, interpolation is a marker", () => {
    expect(keys(`String(localized: "Count \\(n)", comment: "c")`)).toEqual(["keyed:Count %"]);
    expect(keys(`static let title: LocalizedStringResource = "Stop"`)).toEqual(["keyed:Stop"]);
    expect(
      keys(
        `var localizedStringResource: LocalizedStringResource {\n switch self {\n case .a: "Not ready"\n }\n}`,
      ),
    ).toEqual(["keyed:Not ready"]);
  });

  test("App Intents forms", () => {
    expect(keys(`IntentDescription("Start a memo.")\n@Parameter(title: "Destination")`)).toEqual([
      "keyed:Start a memo.",
      "keyed:Destination",
    ]);
  });

  test("data is not a key: verbatim, systemImage, identifiers, no letters, comments, previews", () => {
    const src = `
      Text(verbatim: "raw")
      Label("Copy", systemImage: "doc.on.doc")
      .accessibilityIdentifier("mac.status")
      Text("·")
      // Text("commented out")
      #Preview { Text("Preview only") }
    `;
    expect(keys(src)).toEqual(["keyed:Copy"]);
  });

  test("l10n:ignore on the line or the line above", () => {
    expect(
      keys(`Text("A") // l10n:ignore data\n// l10n:ignore data\nText("B")\nText("C")`),
    ).toEqual(["keyed:C"]);
  });

  test("a ternary of literals in a view init is a String and never localized", () => {
    const hits = scan(`Button(done ? "Not done" : "Done", systemImage: "checkmark") {}`);
    expect(hits.map((h) => h.kind)).toEqual(["string", "string"]);
  });

  test("a ternary with comment: or bundle: picks the localizing init", () => {
    expect(keys(`Text(flag ? "On" : "Off", comment: "state")`)).toEqual(["keyed:On", "keyed:Off"]);
  });

  test("a bare literal for a String argument cannot be localized", () => {
    expect(keys(`Row(title: "Settings", detail: String(localized: "Hint"))`)).toEqual([
      "string:Settings",
      "keyed:Hint",
    ]);
  });

  test("in a package a keyed literal needs bundle:", () => {
    expect(
      keys(
        `Text("A")\nText("B", bundle: #bundle)\nString(localized: "C")\nString(localized: "D", bundle: #bundle)\nButton("E") {}`,
        true,
      ),
    ).toEqual(["bundle:A", "keyed:B", "bundle:C", "keyed:D", "bundle:E"]);
  });

  test("multi-line and raw strings do not derail the lexer", () => {
    const src = `let a = """\n  Text("inside")\n  """\nlet b = #"Text("raw")"#\nText("Real")`;
    expect(keys(src)).toEqual(["keyed:Real"]);
  });

  test("a literal inside an interpolation is an argument, not a key", () => {
    expect(keys(`Text("n: \\(x ? "yes" : "no")")`)).toEqual(["keyed:n: %"]);
  });
});

describe("normalize", () => {
  test("interpolations, specifiers and percent signs compare equal", () => {
    expect(normalize("%lld files · %@")).toBe(normalizeLiteral("\uE000 files · \uE000"));
    expect(normalize("+%lld %% slower")).toBe(normalizeLiteral("+\uE000 % slower"));
    expect(normalize("%1$@ of %2$@")).toBe(normalizeLiteral("\uE000 of \uE000"));
  });
});

describe("checkCatalog", () => {
  const unit = (value: string, state = "translated") => ({ stringUnit: { state, value } });
  const cat = (strings: Catalog["strings"]): Catalog => ({ sourceLanguage: "en", strings });

  test("a complete catalog passes", () => {
    expect(checkCatalog("c", cat({ Save: { localizations: { de: unit("Sichern") } } }))).toEqual(
      [],
    );
  });

  test("a key without de, with an untranslated de, or marked stale fails", () => {
    const errs = checkCatalog(
      "c",
      cat({
        A: { localizations: { en: unit("A") } },
        B: { localizations: { de: unit("B", "needs_review") } },
        C: { extractionState: "stale", localizations: { de: unit("C") } },
      }),
    );
    expect(errs.length).toBe(3);
  });

  test("every plural leaf needs a translation", () => {
    const plural = (one: string, other: string) => ({
      variations: { plural: { one: unit(one), other: unit(other, "new") } },
    });
    expect(
      checkCatalog("c", cat({ "%lld x": { localizations: { de: plural("1 x", "n x") } } })).length,
    ).toBe(1);
  });

  test("format specifiers must match the key, positional ones included", () => {
    expect(
      checkCatalog("c", cat({ "%@ of %@": { localizations: { de: unit("%2$@ von %1$@") } } })),
    ).toEqual([]);
    expect(
      checkCatalog("c", cat({ "%lld files": { localizations: { de: unit("%@ Dateien") } } }))
        .length,
    ).toBe(1);
    expect(
      checkCatalog("c", cat({ "80 %% sure": { localizations: { de: unit("80 %% sicher") } } })),
    ).toEqual([]);
  });

  test("shouldTranslate false is exempt", () => {
    expect(checkCatalog("c", cat({ Iris: { shouldTranslate: false } }))).toEqual([]);
  });
});
