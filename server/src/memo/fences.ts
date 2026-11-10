const FENCE = /^ {0,3}(`{3,}|~{3,})\s*(.*)$/;

/** A top-level fenced block: `lang` is the first word of the info string, lower-cased; `info` the rest, trimmed. */
export interface Fence {
  lang: string;
  info: string;
  source: string;
}

/**
 * Every top-level fenced block of a markdown reply, in document order (CommonMark: a fence closes on the same character,
 * at least as long, with nothing after it; an unclosed one runs to the end). A fence inside another fenced block is that
 * block's text, not a fence of its own.
 */
export function extractFences(markdown: string): Fence[] {
  const fences: Fence[] = [];
  let open: { marker: string; lang: string; info: string; lines: string[] } | null = null;
  const finish = () => {
    if (open) fences.push({ lang: open.lang, info: open.info, source: open.lines.join("\n") });
  };
  for (const line of markdown.split(/\r?\n/)) {
    if (open) {
      const closing = FENCE.exec(line);
      const isClose =
        closing?.[1] !== undefined &&
        closing[1].startsWith(open.marker[0] as string) &&
        closing[1].length >= open.marker.length &&
        closing[2] === "";
      if (!isClose) {
        open.lines.push(line);
        continue;
      }
      finish();
      open = null;
      continue;
    }
    const opening = FENCE.exec(line);
    if (!opening?.[1]) continue;
    const infoString = (opening[2] ?? "").trim();
    // A backtick fence's info string cannot contain a backtick.
    if (opening[1].startsWith("`") && infoString.includes("`")) continue;
    const first = infoString.split(/\s+/)[0] ?? "";
    open = {
      marker: opening[1],
      lang: first.toLowerCase(),
      info: infoString.slice(first.length).trim(),
      lines: [],
    };
  }
  finish();
  return fences;
}
