import type { Scheme, Theme } from "./payload";

/** Sets color-scheme, data-scheme and (when sent) the --iris-* variables on <html>. */
export function applyTheme(theme: Theme, root: HTMLElement = document.documentElement): void {
  root.style.colorScheme = theme.scheme;
  root.dataset.scheme = theme.scheme;
  for (const [name, value] of Object.entries(theme.vars ?? {})) {
    if (name.startsWith("--")) root.style.setProperty(name, value);
  }
}

/** Reads a CSS variable the host (or the dev theme) set on <html>. */
export function cssVar(name: string, fallback: string): string {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
}

export type { Scheme };
