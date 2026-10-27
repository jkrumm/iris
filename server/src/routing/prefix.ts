import type { DestinationName } from "../ports/destination.js";

/** The phrase must start within this many leading words. */
const MAX_START_WORD = 6;

export interface Prefix {
  destination: DestinationName;
  /** Spoken tab name, as typed by the transcriber; only for `herdr`. */
  tab?: string;
  /** The transcript with everything up to and including the phrase (and trailing punctuation) removed. */
  stripped: string;
}

interface Word {
  /** Lowercased, diacritics and surrounding punctuation removed. */
  folded: string;
  /** The word without surrounding punctuation, as written. */
  core: string;
  /** Index in the transcript just past the word, trailing punctuation included. */
  end: number;
}

/** Lowercased with diacritics removed: the comparison form of any spoken or labelled name. */
export const fold = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

const edgePunctuation = /^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu;

function words(transcript: string): Word[] {
  return Array.from(transcript.matchAll(/\S+/g), (match) => {
    const core = match[0].replace(edgePunctuation, "");
    return { folded: fold(core), core, end: match.index + match[0].length };
  });
}

/** Two-word phrases first: at one start position the longest phrase wins. */
function matchAt(
  list: Word[],
  i: number,
): { destination: DestinationName; tab?: string; length: number } | null {
  const first = list[i]?.folded;
  const second = list[i + 1];
  if (first === "an" && second?.folded === "hermes") return { destination: "hermes", length: 2 };
  if (first === "tab" && second && second.core !== "") {
    return { destination: "herdr", tab: second.core, length: 2 };
  }
  if (first === "journal" || first === "tagebuch") return { destination: "journal", length: 1 };
  if (first === "hermes") return { destination: "hermes", length: 1 };
  return null;
}

/**
 * Finds a routing phrase ("journal" | "tagebuch", "an hermes" | "hermes", "tab <name>") that starts within
 * the first 6 words, case- and diacritic-insensitive. The earliest start wins. When nothing would be left
 * of the transcript after stripping, `stripped` is the original text, so the destination never gets an empty memo.
 */
export function parsePrefix(transcript: string): Prefix | null {
  const list = words(transcript);
  for (let i = 0; i < Math.min(list.length, MAX_START_WORD); i++) {
    const match = matchAt(list, i);
    if (!match) continue;
    const last = list[i + match.length - 1];
    if (!last) continue;
    const rest = transcript
      .slice(last.end)
      .replace(/^[^\p{L}\p{N}]+/u, "")
      .trimEnd();
    return {
      destination: match.destination,
      ...(match.tab !== undefined && { tab: match.tab }),
      stripped: rest === "" ? transcript : rest,
    };
  }
  return null;
}

/**
 * The text the destination and the summarizer get. `transcript` stays the raw speech-to-text; when a
 * spoken prefix routed the memo (any `prefix` decision row, so a later answer does not bring the word
 * back) the prefix is cut again, deterministically, so a retry from `route` sees the same input.
 */
export function deliveredTranscript(params: {
  transcript: string;
  decisions: readonly { source: string }[];
}): string {
  const { transcript, decisions } = params;
  if (!decisions.some((d) => d.source === "prefix")) return transcript;
  return parsePrefix(transcript)?.stripped ?? transcript;
}
