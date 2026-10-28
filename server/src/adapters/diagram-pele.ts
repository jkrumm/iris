import { Resvg } from "@resvg/resvg-js";
import { render } from "pele";
import type { DiagramRenderer, RenderedScheme } from "../ports/diagram.js";

// Basalt colours of the two schemes (docs/design/mockups/tokens.css, generated from BasaltTokens), mapped onto Pele's
// CSS variables. The renderer resolves them into the SVG, so the files carry final colours and need no CSS engine.
const FONT = "-apple-system, Helvetica Neue, Helvetica, Arial, sans-serif";

const THEMES = {
  light: {
    bg: "rgb(250 250 253)",
    fg: "rgb(38 38 41)",
    muted: "rgb(82 82 85)",
    line: "rgb(105 105 108)",
    surface: "rgb(255 255 255)",
    surfaceAlt: "rgb(244 244 248)",
    border: "rgb(105 105 108)",
    accent: "rgb(67 116 166)",
    series: [
      "rgb(67 116 166)",
      "rgb(41 166 52)",
      "rgb(147 95 0)",
      "rgb(181 64 61)",
      "rgb(47 119 75)",
      "rgb(113 113 122)",
      "rgb(64 64 67)",
      "rgb(105 105 108)",
    ],
    critical: "rgb(181 64 61)",
  },
  dark: {
    bg: "rgb(43 43 46)",
    fg: "rgb(229 229 233)",
    muted: "rgb(212 212 216)",
    line: "rgb(167 167 170)",
    surface: "rgb(56 56 59)",
    surfaceAlt: "rgb(50 50 53)",
    border: "rgb(167 167 170)",
    accent: "rgb(162 195 240)",
    series: [
      "rgb(162 195 240)",
      "rgb(67 191 77)",
      "rgb(230 165 61)",
      "rgb(254 129 120)",
      "rgb(82 192 124)",
      "rgb(161 161 170)",
      "rgb(221 221 225)",
      "rgb(167 167 170)",
    ],
    critical: "rgb(254 129 120)",
  },
} as const;

type Scheme = keyof typeof THEMES;

/** PNGs are rendered at twice the diagram's size, never beyond this many pixels on the long edge. */
export const PNG_SCALE = 2;
export const PNG_MAX_PX = 4096;

const variablesOf = (scheme: Scheme) => {
  const t = THEMES[scheme];
  return {
    "--pele-bg": t.bg,
    "--pele-fg": t.fg,
    "--pele-muted": t.muted,
    "--pele-line": t.line,
    "--pele-surface": t.surface,
    "--pele-surface-alt": t.surfaceAlt,
    "--pele-border": t.border,
    "--pele-accent": t.accent,
    "--pele-critical": t.critical,
    "--pele-error": t.critical,
    "--pele-font": FONT,
    ...Object.fromEntries(t.series.map((color, i) => [`--pele-series-${i + 1}`, color])),
  };
};

const CUSTOM_PROPERTY = /(--[\w-]+)\s*:\s*([^;"]*)/g;
const VAR = /var\(\s*(--[\w-]+)\s*(?:,\s*((?:[^()]|\([^()]*\))*))?\)/g;

/**
 * Pele colours everything through CSS variables. This sets the scheme's `--pele-*` on the root element, then
 * substitutes every `var()` in the document (the variables defined on the root, else the fallback), so the result
 * renders the same in a browser, in a rasterizer and in any viewer that ignores CSS variables.
 */
export function resolveTheme(svg: string, scheme: Scheme): string {
  const root = /^<svg\b[^>]*?\sstyle="/.exec(svg);
  if (!root) throw new Error("diagram SVG has no root style");
  const declarations = Object.entries(variablesOf(scheme))
    .map(([name, value]) => `${name}:${value}`)
    .join(";");
  const themed = `${svg.slice(0, root[0].length)}background:${THEMES[scheme].bg};${declarations};${svg.slice(root[0].length)}`;

  const rootStyle = /^<svg\b[^>]*?\sstyle="([^"]*)"/.exec(themed)?.[1] ?? "";
  const defined = new Map<string, string>();
  for (const [, name, value] of rootStyle.matchAll(CUSTOM_PROPERTY)) {
    if (name && value !== undefined) defined.set(name, value.trim());
  }
  const resolve = (text: string, depth: number): string =>
    depth > 8
      ? text
      : text.replace(VAR, (_, name: string, fallback?: string) =>
          resolve(defined.get(name) ?? fallback?.trim() ?? "", depth + 1),
        );
  return resolve(themed, 0);
}

function rasterize(svg: string, params: { scheme: Scheme; width: number; height: number }) {
  const { scheme, width, height } = params;
  const zoom = Math.min(PNG_SCALE, PNG_MAX_PX / Math.max(width, height));
  return new Resvg(svg, {
    background: THEMES[scheme].bg,
    fitTo: { mode: "zoom", value: zoom },
    font: { loadSystemFonts: true, defaultFontFamily: "Helvetica" },
  })
    .render()
    .asPng();
}

/**
 * Pele (synchronous Mermaid → SVG, no DOM needed) themed per scheme, rasterized by resvg-js (native, no headless browser).
 * Text in the PNGs is set in the host's system fonts (Helvetica, a macOS standard).
 */
export function createPeleRenderer(): DiagramRenderer {
  return {
    async render(source) {
      const { svg, width: w, height: h } = render(source, { fontFamily: FONT });
      const width = Math.max(1, Math.ceil(w));
      const height = Math.max(1, Math.ceil(h));
      const scheme = (name: Scheme): RenderedScheme => {
        const themed = resolveTheme(svg, name);
        return {
          svg: themed,
          png: new Uint8Array(rasterize(themed, { scheme: name, width, height })),
        };
      };
      return { width, height, light: scheme("light"), dark: scheme("dark") };
    },
  };
}
