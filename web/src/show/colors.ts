import { cssVar } from "../theme";

/** Series order: accent first, then the status colors, then the neutrals. Eight distinct entries. */
const SERIES_TOKENS: [name: string, fallback: string][] = [
  ["--iris-accent", "#4574a6"],
  ["--iris-status-good", "#2f774b"],
  ["--iris-status-warn", "#93600a"],
  ["--iris-status-bad", "#b5403d"],
  ["--iris-status-neutral", "#71717a"],
  ["--iris-status-excellent", "#29a634"],
  ["--iris-faint", "#69696c"],
  ["--iris-ink-2", "#404043"],
];

/** Reads the series colors from the current token values (call on render and on a scheme change). */
export const seriesColors = (): string[] =>
  SERIES_TOKENS.map(([name, fallback]) => cssVar(name, fallback));

/** `rgb(r, g, b)` / `rgba(...)` with another alpha; any other notation is returned as is. */
export function withAlpha(color: string, alpha: number): string {
  const match = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(color);
  return match ? `rgba(${match[1]}, ${match[2]}, ${match[3]}, ${alpha})` : color;
}
