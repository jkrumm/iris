/** Words shorter than this are never corrected: one edit changes too much of them. */
const MIN_CORRECTED_LENGTH = 4;
/** Longest word that gets one edit; longer words get two. */
const SHORT_WORD = 7;
/** How many near terms replace one misspelt word. */
const NEAR_TERMS = 3;

/** One indexed term and the number of memos it occurs in (`memo_fts_vocab`, type row). */
export interface VocabTerm {
  term: string;
  doc: number;
}

const quote = (term: string) => `"${term.replaceAll('"', '""')}"`;

const searchWords = (q: string) =>
  q
    .split(/\s+/)
    .filter(Boolean)
    .filter((word) => /[\p{L}\p{N}]/u.test(word));

/**
 * The FTS5 MATCH expression for a user's search text: every term quoted (embedded quotes doubled, so input
 * never reaches the MATCH syntax as an operator) and prefix-matched, terms ANDed. `undefined`: no search
 * (blank text). `null`: text without a single letter or digit, which matches nothing.
 */
export function ftsMatch(q: string): string | null | undefined {
  if (q.trim() === "") return undefined;
  const words = searchWords(q);
  if (words.length === 0) return null;
  return words.map((word) => `${quote(word)}*`).join(" ");
}

/** Lower case without diacritics, the way the index's `unicode61 remove_diacritics 2` tokenizer folds a term. */
export const fold = (word: string) => word.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Edit distance with insert, delete, substitute and adjacent swap; `max + 1` once it is certain to exceed `max`. */
export function editDistance(a: string, b: string, max: number): number {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  const width = b.length + 1;
  const d: number[] = [];
  const at = (i: number, j: number) => d[i * width + j] ?? 0;
  for (let i = 0; i <= a.length; i++) {
    for (let j = 0; j <= b.length; j++) {
      if (i === 0 || j === 0) {
        d[i * width + j] = i + j;
        continue;
      }
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let best = Math.min(at(i - 1, j) + 1, at(i, j - 1) + 1, at(i - 1, j - 1) + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        best = Math.min(best, at(i - 2, j - 2) + 1);
      }
      d[i * width + j] = best;
    }
  }
  return Math.min(at(a.length, b.length), max + 1);
}

/**
 * The indexed terms nearest to a misspelt word, best first: within one edit for a word up to seven letters, two above.
 * A term counts by its whole or by its leading letters (the search is prefix-matched, so "expre" is near "espresso").
 */
export function nearTerms(word: string, vocab: readonly VocabTerm[]): string[] {
  const max = word.length <= SHORT_WORD ? 1 : 2;
  const found: { term: string; distance: number; doc: number }[] = [];
  for (const { term, doc } of vocab) {
    const distance = Math.min(
      editDistance(word, term, max),
      term.length > word.length ? editDistance(word, term.slice(0, word.length), max) : max + 1,
    );
    if (distance <= max) found.push({ term, distance, doc });
  }
  found.sort((x, y) => x.distance - y.distance || y.doc - x.doc || x.term.localeCompare(y.term));
  return found.slice(0, NEAR_TERMS).map((hit) => hit.term);
}

/**
 * The MATCH expression of a query with its misspelt words corrected against the index vocabulary: a word of four
 * or more letters that no indexed term starts with becomes its near terms ORed, every other word stays a prefix
 * term, and the words are ANDed. `null` when nothing was corrected or a misspelt word has no near term (the
 * query cannot match anyway).
 */
export function correctedMatch(q: string, vocab: readonly VocabTerm[]): string | null {
  let corrected = false;
  const parts: string[] = [];
  for (const word of searchWords(q)) {
    const folded = fold(word);
    const candidate = folded.length >= MIN_CORRECTED_LENGTH && /^\p{L}+$/u.test(folded);
    if (!candidate || vocab.some(({ term }) => term.startsWith(folded))) {
      parts.push(`${quote(word)}*`);
      continue;
    }
    const near = nearTerms(folded, vocab);
    if (near.length === 0) return null;
    corrected = true;
    parts.push(`(${near.map((term) => `${quote(term)}*`).join(" OR ")})`);
  }
  return corrected ? parts.join(" AND ") : null;
}
