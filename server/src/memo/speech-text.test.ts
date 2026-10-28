import { describe, expect, it } from "bun:test";
import {
  detectLanguage,
  markdownToSpeech,
  SPEECH_MAX_CHARS,
  speechVariant,
} from "./speech-text.js";

describe("detectLanguage", () => {
  it("recognises German and English, and defaults to German without signal", () => {
    expect(detectLanguage("Das ist nicht der richtige Weg für die Migration.")).toBe("de");
    expect(detectLanguage("This is not the right way to run the migration.")).toBe("en");
    expect(detectLanguage("```ts\nconst x = 1\n```")).toBe("de");
  });
});

describe("markdownToSpeech", () => {
  it("summarizes a fenced code block in the reply's language", () => {
    const de = "Das ist der Fix für den Fehler:\n\n```ts\nconst a = 1;\n```\n\nDanach läuft es.";
    expect(markdownToSpeech(de)).toBe(
      "Das ist der Fix für den Fehler:\n\nein Codeblock\n\nDanach läuft es.",
    );
    const en = "This is the fix for the error:\n\n```ts\nconst a = 1;\n```\n\nThen it works.";
    expect(markdownToSpeech(en)).toBe(
      "This is the fix for the error:\n\na code block\n\nThen it works.",
    );
  });

  it("summarizes mermaid and other diagram fences as a diagram", () => {
    expect(
      markdownToSpeech("Here it is and the flow:\n```mermaid\ngraph TD; A-->B\n```"),
    ).toContain("a diagram");
    expect(markdownToSpeech("Der Ablauf ist:\n~~~plantuml\n@startuml\n~~~")).toContain(
      "ein Diagramm",
    );
  });

  it("treats a longer closing fence and an unclosed fence correctly", () => {
    expect(
      markdownToSpeech("The code is:\n````md\n```\ninner\n```\n````\nDone, and it is fine."),
    ).toBe("The code is:\n\na code block\n\nDone, and it is fine.");
    expect(markdownToSpeech("The code is:\n```\nnever closed\nstill code")).toBe(
      "The code is:\n\na code block",
    );
  });

  it("recognises a fence nested under a list item, however deep the indentation", () => {
    const de =
      "Das sind die Schritte:\n\n1. Installiere es\n\n    ```sh\n    bun i\n    ```\n\n2. Danach läuft es.";
    expect(markdownToSpeech(de)).toBe(
      "Das sind die Schritte:\n\nInstalliere es.\n\nein Codeblock\n\nDanach läuft es.",
    );
    const en =
      "These are the steps:\n\n- Install it\n\n        ```mermaid\n        graph TD; A-->B\n        ```\n\n- Then it runs.";
    expect(markdownToSpeech(en)).toBe(
      "These are the steps:\n\nInstall it.\n\na diagram\n\nThen it runs.",
    );
  });

  it("does not open a fence on a one-line triple-backtick span", () => {
    expect(markdownToSpeech("```foo``` is the answer.\n\nAnd the rest is still spoken.")).toBe(
      "foo is the answer.\n\nAnd the rest is still spoken.",
    );
    expect(markdownToSpeech("Das ist ```foo``` die Antwort, und der Rest wird gelesen.")).toBe(
      "Das ist foo die Antwort, und der Rest wird gelesen.",
    );
    // a tilde fence may carry backticks in its info string
    expect(markdownToSpeech("The code is:\n~~~ a`b\nx\n~~~\nDone, and it is fine.")).toContain(
      "a code block",
    );
  });

  it("summarizes a one-column table but not a horizontal rule", () => {
    expect(markdownToSpeech("The names are:\n\n| name |\n| --- |\n| a |\n| b |")).toBe(
      "The names are:\n\na table with 2 rows",
    );
    expect(markdownToSpeech("Erster Teil ist da.\n\n---\n\nZweiter Teil ist da.")).toBe(
      "Erster Teil ist da.\n\nZweiter Teil ist da.",
    );
  });

  it("summarizes a table with its data row count", () => {
    const table =
      "The results are:\n\n| name | value |\n|-|-|\n| a | 1 |\n| b | 2 |\n| c | 3 |\n\nThat is all.";
    expect(markdownToSpeech(table)).toBe("The results are:\n\na table with 3 rows\n\nThat is all.");
    expect(markdownToSpeech("Das ist die Liste:\n\n| a | b |\n| --- | :-: |\n| 1 | 2 |")).toBe(
      "Das ist die Liste:\n\neine Tabelle mit 1 Zeile",
    );
  });

  it("keeps link text and drops urls, bare and autolinked", () => {
    expect(markdownToSpeech("Read [the docs](https://example.com/a?b=1) for the details.")).toBe(
      "Read the docs for the details.",
    );
    expect(markdownToSpeech("Das steht auf https://example.com/path und ist gut.")).toBe(
      "Das steht auf und ist gut.",
    );
    expect(markdownToSpeech("See the page at https://example.com/path.")).toBe("See the page at.");
    expect(markdownToSpeech("It is here <https://example.com> and www.example.com/x too.")).toBe(
      "It is here and too.",
    );
    expect(markdownToSpeech("![a chart](https://example.com/c.png) is the chart.")).toBe(
      "a chart is the chart.",
    );
  });

  it("removes headings, emphasis, list markers, quotes and inline code ticks", () => {
    const md = [
      "# Ergebnis",
      "",
      "Das ist **wichtig** und _betont_ und ~~falsch~~.",
      "",
      "- erster Punkt",
      "* zweiter `code` Punkt",
      "1. dritter Punkt.",
      "- [x] erledigt",
      "",
      "> Zitat vom Chef",
      "",
      "---",
    ].join("\n");
    expect(markdownToSpeech(md)).toBe(
      "Ergebnis.\n\nDas ist wichtig und betont und falsch.\n\nerster Punkt. zweiter code Punkt. dritter Punkt. erledigt.\n\nZitat vom Chef",
    );
  });

  it("leaves snake_case identifiers and math-like asterisks alone and unescapes", () => {
    expect(markdownToSpeech("The my_var_name is set and 2 * 3 is six.")).toBe(
      "The my_var_name is set and 2 * 3 is six.",
    );
    expect(markdownToSpeech("Das ist \\*kein\\* Stern und `a_b*c` bleibt.")).toBe(
      "Das ist *kein* Stern und a_b*c bleibt.",
    );
  });

  it("drops reference link definitions and html tags", () => {
    expect(markdownToSpeech("See [the spec][1] for it.\n\n[1]: https://example.com/spec\n")).toBe(
      "See the spec for it.",
    );
    expect(markdownToSpeech("Das ist <b>fett</b><br> und gut.")).toBe("Das ist fett und gut.");
  });

  it("is idempotent on already plain text and empty on empty input", () => {
    const plain = "Das ist ein normaler Satz. Und noch einer.";
    expect(markdownToSpeech(plain)).toBe(plain);
    expect(markdownToSpeech("")).toBe("");
    expect(markdownToSpeech("\n\n  \n")).toBe("");
  });

  it("never leaves markdown syntax in a mixed reply", () => {
    const md =
      "## Plan\n\n1. **Install** `bun`\n2. Run [setup](https://example.com)\n\n```sh\nbun i\n```\n\n| a | b |\n|-|-|\n| 1 | 2 |";
    const out = markdownToSpeech(md, "en");
    expect(out).not.toMatch(/[#*`|\]]|https?:|\(\)/);
    expect(out).toContain("a code block");
    expect(out).toContain("a table with 1 row");
  });
});

describe("speechVariant", () => {
  const long = `${"Das ist ein langer Satz über die Migration. ".repeat(30)}`;

  it("speaks a short reply cleaned, not the summary", () => {
    expect(speechVariant({ reply: "Das ist **gut**.", spoken: "Gut." })).toBe("Das ist gut.");
  });

  it("speaks the summary alone when there is no reply", () => {
    expect(speechVariant({ reply: null, spoken: "Saved to your journal." })).toBe(
      "Saved to your journal.",
    );
    expect(speechVariant({ reply: "  ", spoken: "Erledigt." })).toBe("Erledigt.");
    expect(speechVariant({ reply: null, spoken: null })).toBe("");
  });

  it("speaks the summary plus 'details on screen' past the threshold, in the reply's language", () => {
    expect(long.length).toBeGreaterThan(SPEECH_MAX_CHARS);
    expect(speechVariant({ reply: long, spoken: "Die Migration ist fertig." })).toBe(
      "Die Migration ist fertig. Details auf dem Bildschirm.",
    );
    const en = "This is a long sentence about the migration. ".repeat(30);
    expect(speechVariant({ reply: en, spoken: "The migration is done." })).toBe(
      "The migration is done. Details on screen.",
    );
  });

  it("measures the threshold on the cleaned text: a huge code block does not push a short reply over", () => {
    const reply = `Das ist der Fix:\n\n\`\`\`ts\n${"const a = 1;\n".repeat(200)}\`\`\``;
    expect(speechVariant({ reply, spoken: "Fix." })).toBe("Das ist der Fix:\n\nein Codeblock");
  });

  it("clips whole sentences when a long reply has no summary", () => {
    const out = speechVariant({ reply: long, spoken: null });
    expect(out.length).toBeLessThanOrEqual(SPEECH_MAX_CHARS);
    expect(out.endsWith(" Details auf dem Bildschirm.")).toBe(true);
    expect(out).toContain("Migration. Details");
  });

  it("speaks the summary in the reply's language, not its own", () => {
    const en = "This is a long sentence about the migration. ".repeat(30);
    expect(speechVariant({ reply: en, spoken: "Ein Fenster `foo` in der Datei." })).toBe(
      "Ein Fenster foo in der Datei. Details on screen.",
    );
  });

  it("caps an oversized summary", () => {
    const spoken = "Die Migration ist fertig und läuft. ".repeat(40);
    const out = speechVariant({ reply: long, spoken });
    expect(out.length).toBeLessThanOrEqual(SPEECH_MAX_CHARS);
    expect(out.endsWith(" Details auf dem Bildschirm.")).toBe(true);
    expect(speechVariant({ reply: null, spoken }).length).toBeLessThanOrEqual(SPEECH_MAX_CHARS);
  });

  it("clips at a sentence that ends exactly at the cut", () => {
    const room = SPEECH_MAX_CHARS - "Details auf dem Bildschirm.".length - 1;
    const first = `${"x".repeat(room - 1)}.`;
    const reply = `${first} ${"Das ist ein langer Satz über die Migration. ".repeat(30)}`;
    expect(speechVariant({ reply, spoken: null })).toBe(`${first} Details auf dem Bildschirm.`);
  });

  it("is deterministic: the same inputs give the same text (the cache key)", () => {
    const params = { reply: long, spoken: "Fertig." };
    expect(speechVariant(params)).toBe(speechVariant({ ...params }));
  });
});
