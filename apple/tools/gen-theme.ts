// Generates apple/Packages/IrisUI/Sources/IrisUI/Theme/BasaltTokens.generated.swift from basalt-ui.
//
//   cd apple/tools && bun install --frozen-lockfile && bun gen-theme.ts [--check]
//
// Only `basalt-ui/tokens` is imported (Mantine/React free). Values are read from the public
// `buildPaletteCss()` output, so the Swift tokens resolve exactly like the web `--vx-*` variables.
import { buildPaletteCss } from "basalt-ui/tokens";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const toolsDir = dirname(fileURLToPath(import.meta.url));
const outPath = join(
  toolsDir,
  "../Packages/IrisUI/Sources/IrisUI/Theme/BasaltTokens.generated.swift",
);
const { version } = JSON.parse(
  readFileSync(join(toolsDir, "node_modules/basalt-ui/package.json"), "utf8"),
) as { version: string };

type Rgba = { r: number; g: number; b: number; a: number };

const css = buildPaletteCss({
  scheme: { attribute: "data-theme", darkValue: "dark", lightValue: "light" },
  defaultScheme: "none",
  only: "core",
});

// Declarations of the first block whose selector equals `selector` (media blocks are nested, so
// they never match a top-level selector string).
function declarations(selector: string): Map<string, string> {
  const start = css.indexOf(`\n${selector} {`);
  const from = start === -1 ? css.startsWith(`${selector} {`) ? 0 : -1 : start + 1;
  if (from === -1) throw new Error(`selector not found in basalt css: ${selector}`);
  const body = css.slice(css.indexOf("{", from) + 1, css.indexOf("}", from));
  const map = new Map<string, string>();
  for (const line of body.split(";")) {
    const m = line.match(/^\s*--([\w-]+):\s*(.+?)\s*$/s);
    if (m) map.set(m[1], m[2]);
  }
  return map;
}

function parseColor(value: string): Rgba {
  const hex = value.match(/^#([0-9a-f]{6})$/i);
  if (hex) {
    const n = parseInt(hex[1], 16);
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 };
  }
  const rgb = value.match(/^rgba?\(\s*(\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\s*\)$/);
  if (rgb) return { r: +rgb[1], g: +rgb[2], b: +rgb[3], a: rgb[4] === undefined ? 1 : +rgb[4] };
  throw new Error(`unsupported color format: ${value}`);
}

const num = (n: number): string => {
  const s = String(Math.round(n * 1e6) / 1e6);
  return s.includes(".") || s.includes("e") ? s : `${s}.0`;
};
const rgbaSwift = (c: Rgba): string =>
  `RGBA(red: ${num(c.r / 255)}, green: ${num(c.g / 255)}, blue: ${num(c.b / 255)}, alpha: ${num(c.a)})`;

const light = declarations(":root[data-theme='light']");
const dark = declarations(":root[data-theme='dark']");
const root = declarations(":root");

// [swift name, css variable]
const colorTokens: [string, string][] = [
  ["surfaceBg", "vx-surface-bg"],
  ["surfacePanel", "vx-surface-panel"],
  ["surfaceElevated", "vx-surface-elevated"],
  ["surfaceSubtle", "vx-surface-subtle"],
  ["surfaceBorder", "vx-surface-border"],
  ["surfaceHairline", "vx-surface-hairline"],
  ["ink", "vx-ink"],
  ["ink2", "vx-ink2"],
  ["muted", "vx-muted"],
  ["faint", "vx-faint"],
  ["accent", "vx-accent"],
  ["accentFill", "vx-accent-fill"],
  ["onAccent", "vx-on-accent"],
  ["divider", "vx-divider"],
  ["statusExcellent", "vx-status-excellent"],
  ["statusGood", "vx-status-good"],
  ["statusWarn", "vx-status-warn"],
  ["statusBad", "vx-status-bad"],
  ["statusNeutral", "vx-status-neutral"],
];

const px = (map: Map<string, string>, name: string): number => {
  const v = map.get(name)?.match(/^([\d.]+)px$/);
  if (!v) throw new Error(`expected a px value for --${name}`);
  return +v[1];
};
const lowerFirst = (s: string): string => s.charAt(0).toLowerCase() + s.slice(1);
const camel = (s: string): string => s.replace(/-(\w)/g, (_, c: string) => c.toUpperCase());

const radiusNames = ["card", "ctrl", "tight", "fine", "floating"];
const spaceNames = ["xs", "sm", "md", "lg", "xl"];
const textNames = ["nano", "micro", "xs", "sm", "md", "lg", "xl", "h2", "kpi", "h1", "display"];

const colorLines = colorTokens.map(([name, variable]) => {
  const l = light.get(variable);
  const d = dark.get(variable);
  if (!l || !d) throw new Error(`missing --${variable} in light or dark block`);
  return `    static let ${name} = ColorPair(\n      light: ${rgbaSwift(parseColor(l))},\n      dark: ${rgbaSwift(parseColor(d))})`;
});
const constLines = (names: string[], prefix: string, map: Map<string, string>) =>
  names.map((n) => `    static let ${lowerFirst(camel(n))}: Double = ${num(px(map, `${prefix}${n}`))}`);

const swift = `// GENERATED FILE. DO NOT EDIT.
// Source: basalt-ui ${version} (the \`--vx-*\` tokens, read via \`basalt-ui/tokens\`).
// Regenerate: cd apple/tools && bun install --frozen-lockfile && bun gen-theme.ts
// CI gate:    cd apple/tools && bun gen-theme.ts --check

/// An sRGB color with straight alpha; components are 0...1.
struct RGBA: Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

/// One token resolved per color scheme.
struct ColorPair: Equatable, Sendable {
  var light: RGBA
  var dark: RGBA
}

enum BasaltTokens {
  static let basaltVersion = "${version}"

  enum Colors {
${colorLines.join("\n")}
  }

  /// Corner radii in points.
  enum Radius {
${constLines(radiusNames, "vx-radius-", root).join("\n")}
  }

  /// Stack rhythm in points (\`--vx-space-stack-*\`).
  enum Spacing {
${constLines(spaceNames, "vx-space-stack-", root).join("\n")}
  }

  /// Type scale in points (\`--vx-text-*\`).
  enum TextSize {
${constLines(textNames, "vx-text-", root).join("\n")}
  }
}
`;

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(outPath, "utf8");
  } catch {
    // missing file counts as drift
  }
  if (current !== swift) {
    console.error(`${outPath} is stale. Run: cd apple/tools && bun gen-theme.ts`);
    process.exit(1);
  }
  console.log(`BasaltTokens.generated.swift is up to date (basalt-ui ${version}).`);
} else {
  writeFileSync(outPath, swift);
  console.log(`wrote ${outPath} (basalt-ui ${version})`);
}
