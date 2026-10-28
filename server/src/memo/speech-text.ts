/**
 * The speech-ready variant of an answer (TDD §3, speech): what `GET /v1/memos/:id/speech` and every spoken
 * reply synthesize instead of the stored markdown. Pure and derived on demand, never stored: the speech
 * cache is keyed on the variant text, so a changed reply re-synthesizes and an unchanged one hits.
 */

/** Cleaned replies up to this many characters (about 40 s aloud) are spoken whole; longer ones fall back to the summary. */
export const SPEECH_MAX_CHARS = 600;

type Language = "de" | "en";

const PHRASES = {
  de: {
    code: "ein Codeblock",
    diagram: "ein Diagramm",
    table: (rows: number) => `eine Tabelle mit ${rows} ${rows === 1 ? "Zeile" : "Zeilen"}`,
    details: "Details auf dem Bildschirm.",
  },
  en: {
    code: "a code block",
    diagram: "a diagram",
    table: (rows: number) => `a table with ${rows} ${rows === 1 ? "row" : "rows"}`,
    details: "Details on screen.",
  },
} as const;

// Frequent function words that separate the two languages; code and URLs are stripped before counting.
const GERMAN_WORDS = new Set([
  "der",
  "die",
  "das",
  "und",
  "ist",
  "nicht",
  "ein",
  "eine",
  "mit",
  "für",
  "auf",
  "den",
  "dem",
  "zu",
  "von",
  "es",
  "ich",
  "sie",
  "wir",
  "auch",
  "sich",
  "wird",
  "wurde",
  "aber",
  "oder",
  "dass",
  "im",
  "als",
  "bei",
  "noch",
  "nur",
  "kann",
  "habe",
  "hat",
  "sind",
  "war",
  "wenn",
  "dann",
]);
const ENGLISH_WORDS = new Set([
  "the",
  "and",
  "is",
  "not",
  "a",
  "an",
  "with",
  "for",
  "on",
  "of",
  "to",
  "in",
  "it",
  "i",
  "you",
  "we",
  "also",
  "was",
  "were",
  "but",
  "or",
  "that",
  "as",
  "at",
  "only",
  "can",
  "have",
  "has",
  "are",
  "this",
  "then",
  "if",
  "will",
  "be",
]);

/** German unless English words clearly win: the transcripts are mostly German, so a tie or no signal is German. */
export function detectLanguage(markdown: string): Language {
  const prose = markdown
    .replace(/(`{3,}|~{3,})[\s\S]*?(\1|$)/g, " ")
    .replace(/`[^`]*`/g, " ")
    .replace(/\b(?:https?:\/\/|www\.)\S+/gi, " ");
  let de = 0;
  let en = 0;
  for (const word of prose.toLowerCase().match(/[\p{L}]+/gu) ?? []) {
    if (GERMAN_WORDS.has(word)) de++;
    if (ENGLISH_WORDS.has(word)) en++;
  }
  return en > de ? "en" : "de";
}

const DIAGRAM_LANGS = new Set(["mermaid", "plantuml", "puml", "dot", "graphviz", "d2", "ditaa"]);
const FENCE_OPEN = /^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)/;
const TABLE_SEPARATOR = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$/;
const SENTENCE_END = /[.!?:;…]["')\]]?$/;

/** Fences and tables become one-line summaries; everything else passes through for the inline pass. */
function summarizeBlocks(lines: string[], phrases: (typeof PHRASES)[Language]): string[] {
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";

    const fence = FENCE_OPEN.exec(line);
    if (fence) {
      const marker = fence[1] ?? "```";
      const closing = new RegExp(`^\\s{0,3}${marker[0]}{${marker.length},}\\s*$`);
      let end = i + 1;
      while (end < lines.length && !closing.test(lines[end] ?? "")) end++;
      out.push(
        "",
        DIAGRAM_LANGS.has((fence[2] ?? "").toLowerCase()) ? phrases.diagram : phrases.code,
        "",
      );
      i = end; // an unclosed fence runs to the end of the reply
      continue;
    }

    const next = lines[i + 1];
    if (line.includes("|") && next !== undefined && TABLE_SEPARATOR.test(next)) {
      let end = i + 2;
      while (
        end < lines.length &&
        (lines[end] ?? "").includes("|") &&
        (lines[end] ?? "").trim() !== ""
      ) {
        end++;
      }
      out.push("", phrases.table(end - (i + 2)), "");
      i = end - 1;
      continue;
    }

    out.push(line);
  }
  return out;
}

/** Markup that survives on a single line, removed. Inline code is parked first so its contents stay literal. */
function stripInline(line: string): string {
  const literal: string[] = [];
  const park = (value: string) => `\uE000${literal.push(value) - 1}\uE000`;
  let text = line
    .replace(/\\([\\`*_{}[\]()#+\-.!|~>])/g, (_, char: string) => park(char))
    .replace(/(`+)(.+?)\1/g, (_, __, body: string) => park(body.trim()));
  text = text
    .replace(/<\/?[a-zA-Z][^>\n]*>/g, "") // inline html and <https://autolinks>
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1") // images keep their alt text
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1") // links keep their text, drop the url
    .replace(/\[([^\]]+)\]\[[^\]]*\]/g, "$1")
    .replace(/\b(?:https?:\/\/|www\.)[^\s<>)\]]*[^\s<>)\].,;:!?'"]/gi, "")
    .replace(/\*\*(?=\S)(.+?)(?<=\S)\*\*/g, "$1")
    .replace(/(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])/g, "$1")
    .replace(/\*(?=[^\s*])(.+?)(?<=[^\s*])\*/g, "$1")
    .replace(/(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])/g, "$1")
    .replace(/~~(?=\S)(.+?)(?<=\S)~~/g, "$1");
  return text.replace(/\uE000(\d+)\uE000/g, (_, index: string) => literal[Number(index)] ?? "");
}

/** One line of block-level markdown to plain text, or null when the line carries no words (a rule, a setext underline). */
function stripLine(raw: string): string | null {
  const line = raw.trim();
  if (line === "") return "";
  if (/^([-*_])(\s*\1){2,}$/.test(line) || /^=+$/.test(line)) return null;

  const heading = /^#{1,6}\s+(.*?)(\s+#+)?$/.exec(line);
  const item = /^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.*)$/.exec(line);
  const quote = /^>+\s?(.*)$/.exec(line);
  const body = heading?.[1] ?? item?.[1] ?? quote?.[1] ?? line;

  const text = stripInline(body).replace(/\s+/g, " ").trim();
  if (text === "") return null;
  // Headings and list items have no full stop of their own; without one the voice runs them together.
  return (heading || item) && !SENTENCE_END.test(text) ? `${text}.` : text;
}

/** Markdown to text a voice can read: no syntax, no code, no table cells, no URLs. */
export function markdownToSpeech(
  markdown: string,
  language: Language = detectLanguage(markdown),
): string {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const stripped = summarizeBlocks(lines, PHRASES[language])
    // Reference definitions (`[1]: https://…`) are all url.
    .filter((line) => !/^\s{0,3}\[[^\]]+\]:\s+\S+/.test(line))
    .map(stripLine);

  const paragraphs: string[] = [];
  let current: string[] = [];
  const flush = () => {
    if (current.length > 0) paragraphs.push(current.join(" "));
    current = [];
  };
  for (const line of stripped) {
    if (line === "") flush();
    else if (line !== null) current.push(line);
  }
  flush();

  return paragraphs
    .join("\n\n")
    .replace(/\s+([.,;:!?])/g, "$1") // where a url or link was dropped
    .replace(/([.!?])(\s*[.,;])+/g, "$1")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

/** The longest run of whole sentences that fits `max`, else a hard cut at a word. */
function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  const head = text.slice(0, max);
  const sentence = Math.max(head.lastIndexOf(". "), head.lastIndexOf("! "), head.lastIndexOf("? "));
  if (sentence > max / 2) return head.slice(0, sentence + 1);
  const word = head.lastIndexOf(" ");
  return `${(word > 0 ? head.slice(0, word) : head).replace(/[,;:\s]+$/, "")}.`;
}

/**
 * What to speak for a memo. A reply is spoken as cleaned text when it fits `SPEECH_MAX_CHARS`; a longer one
 * speaks the triage `spoken` summary plus "details on screen" (the first sentences of the reply when the
 * summary is missing). Without a reply the summary is all there is. The summary phrases follow the reply's
 * language, since a German transcript usually gets a German answer.
 */
export function speechVariant(params: { reply: string | null; spoken: string | null }): string {
  const reply = params.reply?.trim() ?? "";
  const spoken = params.spoken ? markdownToSpeech(params.spoken) : "";
  if (reply === "") return spoken;

  const language = detectLanguage(reply);
  const cleaned = markdownToSpeech(reply, language);
  if (cleaned.length <= SPEECH_MAX_CHARS) return cleaned || spoken;

  const lead = spoken || clip(cleaned, SPEECH_MAX_CHARS - PHRASES[language].details.length - 1);
  return `${lead} ${PHRASES[language].details}`;
}
