import type { DestinationName } from "../ports/destination.js";

/** The phrase must start within this many leading words. */
const MAX_START_WORD = 6;
/** A spoken tab name is at most this many words (the phrase "tab <name>" then still fits the 6-word window from the start). */
const MAX_TAB_WORDS = MAX_START_WORD - 1;

export interface Prefix {
  destination: DestinationName;
  /** Spoken tab name, as typed by the transcriber; only for `herdr`. */
  tab?: string;
  /** The transcript with everything up to and including the phrase (and trailing punctuation) removed. */
  stripped: string;
  /** How many leading words of the transcript that cut covers (words before the phrase included); recorded on the decision row. */
  words: number;
}

interface Word {
  /** Lowercased, diacritics and surrounding punctuation removed. */
  folded: string;
  /** The word without surrounding punctuation, as written. */
  core: string;
  /** Index in the transcript just past the word, trailing punctuation included. */
  end: number;
  /** The word ends in punctuation: a spoken name does not run on past it. */
  closes: boolean;
}

/** Lowercased with diacritics removed: the comparison form of any spoken or labelled name. */
export const fold = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Comparison form of a spoken tab name or a tab label: folded, every run of punctuation a single space ("iris-server" = "iris server"). */
export const nameKey = (text: string) =>
  fold(text)
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();

const edgePunctuation = /^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu;

function words(transcript: string): Word[] {
  return Array.from(transcript.matchAll(/\S+/g), (match) => {
    const core = match[0].replace(edgePunctuation, "");
    return {
      folded: fold(core),
      core,
      end: match.index + match[0].length,
      closes: /[^\p{L}\p{N}]$/u.test(match[0]),
    };
  });
}

/**
 * Words after "tab" that name the tab: the longest run (up to 5, none empty, none past one that closes
 * with punctuation) that equals a live label, else the first word alone, which `route` then fails to resolve with a reason.
 */
function tabNameLength(list: Word[], from: number, tabNames: ReadonlySet<string>): number {
  let span = 0;
  for (let j = from; j < list.length && span < MAX_TAB_WORDS; j++) {
    const word = list[j];
    if (!word || word.core === "") break;
    span++;
    if (word.closes) break;
  }
  for (let count = span; count > 1; count--) {
    const spoken = list.slice(from, from + count).map((w) => w.core);
    if (tabNames.has(nameKey(spoken.join(" ")))) return count;
  }
  return 1;
}

/** Longer phrases first: at one start position the longest phrase wins. */
function matchAt(
  list: Word[],
  i: number,
  tabNames: ReadonlySet<string>,
): { destination: DestinationName; tab?: string; length: number } | null {
  const first = list[i]?.folded;
  const second = list[i + 1];
  if (first === "an" && second?.folded === "hermes") return { destination: "hermes", length: 2 };
  if (first === "tab" && second && second.core !== "") {
    const count = tabNameLength(list, i + 1, tabNames);
    const tab = list
      .slice(i + 1, i + 1 + count)
      .map((w) => w.core)
      .join(" ");
    return { destination: "herdr", tab, length: 1 + count };
  }
  if (first === "journal" || first === "tagebuch") return { destination: "journal", length: 1 };
  if (first === "hermes") return { destination: "hermes", length: 1 };
  return null;
}

/** The transcript after its first `count` words and the punctuation behind them; whole when nothing would be left. */
function cutWords(transcript: string, list: Word[], count: number): string {
  const last = list[count - 1];
  if (!last) return transcript;
  const rest = transcript
    .slice(last.end)
    .replace(/^[^\p{L}\p{N}]+/u, "")
    .trimEnd();
  return rest === "" ? transcript : rest;
}

/**
 * Finds a routing phrase ("journal" | "tagebuch", "an hermes" | "hermes", "tab <name>") that starts within
 * the first 6 words, case- and diacritic-insensitive. The earliest start wins. A tab name is one word unless
 * `tabLabels` (the live tab and repo labels) holds a longer run of the words after "tab": the longest such
 * label wins, so "tab iris server ops" names the tab "iris-server-ops", not "iris-server". When nothing would be left
 * of the transcript after stripping, `stripped` is the original text, so the destination never gets an empty memo.
 */
export function parsePrefix(transcript: string, tabLabels: readonly string[] = []): Prefix | null {
  const list = words(transcript);
  const tabNames = new Set(tabLabels.map(nameKey));
  for (let i = 0; i < Math.min(list.length, MAX_START_WORD); i++) {
    const match = matchAt(list, i, tabNames);
    if (!match) continue;
    const count = i + match.length;
    return {
      destination: match.destination,
      ...(match.tab !== undefined && { tab: match.tab }),
      stripped: cutWords(transcript, list, count),
      words: count,
    };
  }
  return null;
}

/**
 * The text the destination and the summarizer get. `transcript` stays the raw speech-to-text; when a
 * spoken prefix routed the memo (any `prefix` decision row, so a later answer does not bring the word
 * back) the prefix is cut again, deterministically, so a retry from `route` sees the same input. The cut is the word
 * count the decision recorded (a multi-word tab name cannot be told from speech without the herd it was matched against);
 * a row from before the count existed is cut by parsing the transcript again.
 */
export function deliveredTranscript(params: {
  transcript: string;
  decisions: readonly { source: string; prefixWords?: number }[];
}): string {
  const { transcript, decisions } = params;
  const prefixRows = decisions.filter((d) => d.source === "prefix");
  if (prefixRows.length === 0) return transcript;
  const counted = prefixRows.findLast((d) => d.prefixWords !== undefined);
  if (counted?.prefixWords !== undefined) {
    return cutWords(transcript, words(transcript), counted.prefixWords);
  }
  return parsePrefix(transcript)?.stripped ?? transcript;
}
