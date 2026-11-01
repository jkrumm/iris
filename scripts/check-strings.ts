#!/usr/bin/env bun
/**
 * String-catalog check (TDD §4 "Localization"). `make check-strings`, part of `make check`.
 *
 * Fails on:
 *  1. a catalog key without a translated `de` value (plural / device variations: every leaf), or a `de` value whose
 *     format specifiers differ from the key's;
 *  2. a stale key: a catalog key no source literal of that target names (`extractionState: manual` keys are exempt:
 *     they are looked up dynamically);
 *  3. a user-facing literal that is not localized: `Text("..")`, `Button("..")`, `Label("..")`, `.navigationTitle("..")`, ...
 *     (SwiftUI `LocalizedStringKey` initializers), `String(localized: "..")`, `LocalizedStringResource("..")`, whose key is not
 *     in the catalog of every target that compiles the file; and a `title:` / `message:` / ... string argument given a bare
 *     literal (a `String` never reaches a catalog).
 *  4. in a Swift package: a keyed literal without `bundle:` (it would look in the app's bundle and show English).
 *  5. `NS*UsageDescription` in a target's Info.plist properties without a translated `InfoPlist.xcstrings` key.
 *
 * Limits (honest): a lexer, not a type checker. It sees literals at the call site only, so a `String` built elsewhere and
 * passed to `Text(variable)` is invisible; a literal with no letter is data; `Text(verbatim:)` is data; a view init this
 * script does not know is not checked (extend `VIEW_INITS`). Telemetry, logs and accessibility identifiers are not
 * user-facing and are not matched. Escape hatch for a literal that is really data: `// l10n:ignore <why>` on its line or
 * the line above. `#Preview` bodies are skipped.
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

// ---------------------------------------------------------------------------------------------------------------------
// Swift lexing

export type Hit = {
  file: string;
  line: number;
  /** The literal as a catalog key: `\(x)` interpolation became `\uE000`. */
  key: string;
  /** `keyed`: must be a catalog key. `string`: a String argument, can never be localized. `bundle`: keyed, without a bundle in a package. */
  kind: "keyed" | "string" | "bundle";
  form: string;
};

const VIEW_INITS = new Set([
  "Text",
  "Button",
  "Label",
  "Toggle",
  "Section",
  "Picker",
  "TextField",
  "SecureField",
  "TextEditor",
  "Menu",
  "NavigationLink",
  "ProgressView",
  "Link",
  "ShareLink",
  "LabeledContent",
  "DisclosureGroup",
  "ContentUnavailableView",
  "Tab",
  "GroupBox",
  "Stepper",
  "DatePicker",
  "Gauge",
  "SettingsLink",
  "PhotosPicker",
  "EditButton",
  "ControlWidgetButton",
  "ControlWidgetToggle",
]);
const MODIFIERS = new Set([
  "navigationTitle",
  "navigationSubtitle",
  "accessibilityLabel",
  "accessibilityHint",
  "accessibilityValue",
  "alert",
  "confirmationDialog",
  "help",
  "badge",
  "prompt",
  "searchable",
  "swipeActions",
  "toolbarTitleMenu",
  "contentUnavailable",
  "displayName",
  "description",
  "configurationDisplayName",
  "accessibilityInputLabels",
]);
const KEYED_CALLS = new Set(["LocalizedStringResource", "LocalizedStringKey", "IntentDescription"]);
/** `callee(label: "x")` forms whose argument is a `LocalizedStringResource` (App Intents). */
const KEYED_LABELS: Record<string, string[]> = {
  Parameter: ["title"],
  TypeDisplayRepresentation: ["name"],
  DisplayRepresentation: ["title", "subtitle"],
};
/** Fake and sample files hold server-shaped data, which is never localized. */
const DATA_FILE = /\/(Sample|Fake)\w*\.swift$/;
/** `String` parameters of our own views and models that end up on screen. */
const STRING_LABELS = new Set([
  "title",
  "subtitle",
  "detail",
  "message",
  "placeholder",
  "caption",
  "hint",
  "prompt",
  "headline",
  "label",
  "footer",
  "header",
  "emptyTitle",
  "emptyMessage",
]);

type Frame = {
  open: string;
  callee: string;
  start: number;
  preview: boolean;
  resource: boolean;
  close?: number;
};
type Lit = {
  start: number;
  end: number;
  value: string;
  stack: Frame[];
  /** Label directly before the literal (`title: "x"`), if any. */
  label: string | null;
  first: boolean;
  /** `x ? "a" : "b"`: the literal is an operand of a ternary. */
  ternary: boolean;
  /** `let title: LocalizedStringResource = "x"`. */
  resourceDecl: boolean;
};

/** Lex Swift source: string literals with their enclosing call frames, `#Preview` bodies and comments dropped. */
export function lex(src: string): { literals: Lit[]; text: string } {
  const literals: Lit[] = [];
  const stack: Frame[] = [];
  // Comments become spaces so offsets and line numbers hold.
  let text = "";
  let i = 0;
  const n = src.length;

  const readString = (): Lit => {
    const start = i;
    // raw string delimiter: #"..."#
    let hashes = 0;
    while (src[i] === "#") {
      hashes++;
      i++;
    }
    const multi = src.startsWith('"""', i);
    i += multi ? 3 : 1;
    const closer = (multi ? '"""' : '"') + "#".repeat(hashes);
    const interp = "\\" + "#".repeat(hashes) + "(";
    let value = "";
    while (i < n && !src.startsWith(closer, i)) {
      if (src.startsWith(interp, i)) {
        i += interp.length;
        let depth = 1;
        value += "\uE000";
        // nested code: lex strings inside it so they are literals too
        const innerStart = i;
        while (i < n && depth > 0) {
          const c = src[i];
          if (c === '"') {
            const inner = readString();
            literals.push({ ...inner, stack: [...stack] });
            continue;
          }
          if (c === "(") depth++;
          else if (c === ")") depth--;
          i++;
        }
        void innerStart;
        continue;
      }
      if (src[i] === "\\" && hashes === 0) {
        const nx = src[i + 1];
        value += nx === "n" ? "\n" : nx === "t" ? "\t" : nx;
        i += 2;
        continue;
      }
      value += src[i];
      i++;
    }
    i += closer.length;
    return {
      start,
      end: i,
      value,
      stack: [],
      label: null,
      first: false,
      ternary: false,
      resourceDecl: false,
    };
  };

  while (i < n) {
    const c = src[i];
    if (c === "/" && src[i + 1] === "/") {
      while (i < n && src[i] !== "\n") {
        text += " ";
        i++;
      }
      continue;
    }
    if (c === "/" && src[i + 1] === "*") {
      let depth = 0;
      do {
        if (src[i] === "/" && src[i + 1] === "*") {
          depth++;
          text += "  ";
          i += 2;
        } else if (src[i] === "*" && src[i + 1] === "/") {
          depth--;
          text += "  ";
          i += 2;
        } else {
          text += src[i] === "\n" ? "\n" : " ";
          i++;
        }
      } while (i < n && depth > 0);
      continue;
    }
    if (c === '"' || (c === "#" && /^#+"/.test(src.slice(i, i + 8)))) {
      const lit = readString();
      const before = text.slice(Math.max(0, lit.start - 120), lit.start);
      const top = stack[stack.length - 1];
      lit.stack = [...stack];
      lit.resourceDecl = /:\s*LocalizedStringResource\s*=\s*$/.test(before);
      if (top?.open === "(") {
        // the argument the literal belongs to (through a ternary or a `+`): walk back to the unmatched `(` or the top-level `,`
        let d = 0;
        let j = lit.start - 1;
        for (; j >= 0; j--) {
          const ch = text[j];
          if (ch === ")" || ch === "]" || ch === "}") d++;
          else if (ch === "(" || ch === "[" || ch === "{") {
            if (d === 0) break;
            d--;
          } else if (ch === "," && d === 0) break;
        }
        const seg = text.slice(j + 1, lit.start);
        const argLabel = /^\s*([A-Za-z_]\w*):/.exec(seg);
        lit.label = argLabel?.[1] ?? null;
        lit.first = !argLabel && text[j] === "(";
        lit.ternary =
          !/^\s*$/.test(seg.replace(/^\s*[A-Za-z_]\w*:/, "")) &&
          (/\?\s*$/.test(before) || /\s:\s*$/.test(before));
      }
      literals.push(lit);
      text += src.slice(lit.start, lit.end).replace(/[^\n]/g, "x");
      continue;
    }
    if (c === "(" || c === "{" || c === "[") {
      const before = text.slice(Math.max(0, i - 80), i);
      let callee = "";
      if (c === "(") {
        const m = /([A-Za-z_]\w*)\s*$/.exec(before);
        callee = m?.[1] ?? "";
      }
      const preview = c === "{" && /#Preview\b[^{]*$/.test(before);
      const resource = c === "{" && /:\s*LocalizedStringResource\s*$/.test(before);
      stack.push({ open: c, callee, start: i, preview, resource });
    } else if (c === ")" || c === "}" || c === "]") {
      const f = stack.pop();
      if (f) f.close = i;
    }
    text += c;
    i++;
  }
  return { literals, text };
}

const hasLetter = (s: string) => /\p{L}/u.test(s.replace(/\uE000/g, ""));

const lineOf = (src: string, idx: number) => src.slice(0, idx).split("\n").length;

/** The hits of one Swift file. `inPackage`: bare `Text("x")` would look in the app's bundle. */
export function scanSwift(file: string, src: string, inPackage: boolean): Hit[] {
  const { literals } = lex(src);
  const lines = src.split("\n");
  const hits: Hit[] = [];
  for (const lit of literals) {
    if (lit.stack.some((f) => f.preview)) continue;
    if (!hasLetter(lit.value)) continue;
    const line = lineOf(src, lit.start);
    const ignored =
      /l10n:ignore/.test(lines[line - 1] ?? "") || /l10n:ignore/.test(lines[line - 2] ?? "");
    if (ignored) continue;
    const add0 = (kind: Hit["kind"], form: string) =>
      hits.push({ file, line, key: lit.value, kind, form });
    if (
      lit.resourceDecl ||
      (lit.stack.some((f) => f.resource) && !lit.stack.some((f) => f.open === "(" && f.callee))
    ) {
      add0("keyed", "LocalizedStringResource");
      continue;
    }
    const top = lit.stack[lit.stack.length - 1];
    if (!top || top.open !== "(") continue;
    const callee = top.callee;
    const body = src.slice(top.start, (top.close ?? top.start) + 1);
    const add = (kind: Hit["kind"], form: string) =>
      hits.push({ file, line, key: lit.value, kind, form });
    const bundleOk = /\bbundle:/.test(body);
    // `comment:` and `tableName:` exist only on the `LocalizedStringKey` overloads, so they force the localizing init
    const localizing = /\b(bundle|comment|tableName):/.test(body);

    // String(localized: "x") / AttributedString(localized: "x")
    if (lit.label === "localized" && (callee === "String" || callee === "AttributedString")) {
      add(inPackage && !bundleOk ? "bundle" : "keyed", `${callee}(localized:)`);
      continue;
    }
    if (lit.first && KEYED_CALLS.has(callee)) {
      add(inPackage && !bundleOk ? "bundle" : "keyed", `${callee}(..)`);
      continue;
    }
    if (lit.label && KEYED_LABELS[callee]?.includes(lit.label)) {
      add("keyed", `${callee}(${lit.label}:)`);
      continue;
    }
    // a ternary of literals inside a view init types as String, which SwiftUI never localizes
    if (
      lit.ternary &&
      (lit.first || lit.label === "title" || lit.label === "label") &&
      (VIEW_INITS.has(callee) || MODIFIERS.has(callee)) &&
      !localizing
    ) {
      add("string", "ternary of literals");
      continue;
    }
    // positional argument of a SwiftUI view init or a modifier
    if (
      (lit.first || lit.label === "title" || lit.label === "label") &&
      (VIEW_INITS.has(callee) || MODIFIERS.has(callee))
    ) {
      if (inPackage && callee === "Text" && !bundleOk) add("bundle", "Text(..)");
      else if (inPackage && callee !== "Text" && VIEW_INITS.has(callee))
        add("bundle", `${callee}(..)`);
      else add("keyed", `${callee}(..)`);
      continue;
    }
    // a String-typed argument of our own view or model
    if (
      lit.label &&
      STRING_LABELS.has(lit.label) &&
      !KEYED_CALLS.has(callee) &&
      callee !== "String"
    ) {
      add("string", `${lit.label}:`);
    }
  }
  return hits;
}

// ---------------------------------------------------------------------------------------------------------------------
// Catalogs

type Unit = { state?: string; value?: string };
type Localization = {
  stringUnit?: Unit;
  variations?: Record<string, Record<string, { stringUnit?: Unit; variations?: unknown }>>;
};
type Entry = {
  comment?: string;
  extractionState?: string;
  shouldTranslate?: boolean;
  localizations?: Record<string, Localization>;
};
export type Catalog = { sourceLanguage: string; strings: Record<string, Entry> };

const SPEC =
  /%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|j|t|q)?[@dDuUxXoOfeEgGcCsSpaAF]|%#@\w+@/g;

/**
 * A catalog key with every format specifier as one marker (`\uE000`) and `%%` as `\uE001`, so a source literal
 * (`normalizeLiteral`) with `\(n)` interpolations and a plain `%` compares equal to its key (`%lld`, `%%`).
 */
export const normalize = (key: string) => key.replace(/%%/g, "\uE001").replace(SPEC, "\uE000");
export const normalizeLiteral = (value: string) => value.replace(/%/g, "\uE001");

function specTypes(value: string): string[] {
  const out: string[] = [];
  const positional: Record<number, string> = {};
  for (const m of value.replace(/%%/g, "").matchAll(SPEC)) {
    const s = m[0];
    if (s.startsWith("%#@")) continue;
    const p = /^%(\d+)\$/.exec(s);
    const type = s.replace(/^%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|j|t|q)?/, "");
    const bucket = /[dDuUxXoO]/.test(type)
      ? "int"
      : /[fFeEgGaA]/.test(type)
        ? "float"
        : /[sSc@C]/.test(type)
          ? "obj"
          : type;
    if (p) positional[Number(p[1])] = bucket;
    else out.push(bucket);
  }
  const numbered = Object.keys(positional)
    .map(Number)
    .toSorted((a, b) => a - b)
    .flatMap((k) => positional[k] ?? []);
  return [...out, ...numbered].toSorted();
}

/** Every translated leaf of a localization: `[path, unit]`. */
function leaves(loc: Localization | undefined, path = ""): [string, Unit][] {
  if (!loc) return [];
  if (loc.stringUnit) return [[path || "value", loc.stringUnit]];
  const out: [string, Unit][] = [];
  for (const [kind, cases] of Object.entries(loc.variations ?? {})) {
    for (const [name, sub] of Object.entries(cases))
      out.push(...leaves(sub as Localization, `${path}${kind}.${name}.`));
  }
  return out;
}

export function checkCatalog(file: string, cat: Catalog): string[] {
  const errs: string[] = [];
  for (const [key, entry] of Object.entries(cat.strings)) {
    if (entry.shouldTranslate === false) continue;
    const de = entry.localizations?.["de"];
    const lv = leaves(de);
    if (lv.length === 0) {
      errs.push(`${file}: "${key}" has no de translation`);
      continue;
    }
    for (const [path, unit] of lv) {
      if (unit.state !== "translated" || !unit.value)
        errs.push(`${file}: "${key}" de ${path} is ${unit.state ?? "missing"} (need translated)`);
      else if (!de?.variations) {
        const want = specTypes(key).join(",");
        const got = specTypes(unit.value).join(",");
        if (want !== got)
          errs.push(
            `${file}: "${key}" de value has format specifiers [${got}], the key has [${want}]`,
          );
      }
    }
    if (entry.extractionState === "stale") errs.push(`${file}: "${key}" is marked stale`);
  }
  return errs;
}

// ---------------------------------------------------------------------------------------------------------------------
// Project layout: which Swift files compile into which target, where its catalog lives

export type Target = {
  name: string;
  dir: string;
  files: string[];
  catalog: string;
  isPackage: boolean;
  infoKeys: string[];
};

const walk = (dir: string, accept: (f: string) => boolean): string[] => {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    if (name === ".build" || name === ".dd.noindex" || name === "__Snapshots__") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p, accept));
    else if (accept(p)) out.push(p);
  }
  return out;
};

const swiftIn = (p: string) =>
  statSync(p).isDirectory() ? walk(p, (f) => f.endsWith(".swift")) : [p];

export function targets(root: string): Target[] {
  const apple = join(root, "apple");
  const spec = Bun.YAML.parse(readFileSync(join(apple, "project.yml"), "utf8")) as {
    targets: Record<
      string,
      {
        type: string;
        sources?: (string | { path: string })[];
        info?: { properties?: Record<string, unknown> };
      }
    >;
  };
  const out: Target[] = [];
  for (const [name, t] of Object.entries(spec.targets)) {
    if (name.endsWith("Tests")) continue;
    const srcs = (t.sources ?? []).map((s) => (typeof s === "string" ? s : s.path));
    const files = [...new Set(srcs.flatMap((s) => swiftIn(join(apple, s))))];
    const dir = join(apple, srcs[0] ?? name);
    out.push({
      name,
      dir,
      files,
      catalog: join(dir, "Resources", "Localizable.xcstrings"),
      isPackage: false,
      infoKeys: Object.keys(t.info?.properties ?? {}).filter((k) =>
        /^NS\w+UsageDescription$/.test(k),
      ),
    });
  }
  const pkgs = join(apple, "Packages");
  for (const pkg of readdirSync(pkgs)) {
    const src = join(pkgs, pkg, "Sources");
    if (!existsSync(src)) continue;
    for (const mod of readdirSync(src)) {
      const dir = join(src, mod);
      out.push({
        name: `${pkg}/${mod}`,
        dir,
        files: walk(dir, (f) => f.endsWith(".swift")),
        catalog: join(dir, "Resources", "Localizable.xcstrings"),
        isPackage: true,
        infoKeys: [],
      });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// The check

const readCatalog = (p: string): Catalog | null =>
  existsSync(p) ? (JSON.parse(readFileSync(p, "utf8")) as Catalog) : null;

export function run(root: string): string[] {
  const errs: string[] = [];
  const rel = (p: string) => relative(root, p);
  const used = new Map<string, Set<string>>(); // target name -> normalized keys used
  const all = targets(root);

  // a catalog file anywhere under apple/ must be complete, whether a target claims it or not
  for (const f of walk(join(root, "apple"), (p) => p.endsWith(".xcstrings"))) {
    errs.push(...checkCatalog(rel(f), JSON.parse(readFileSync(f, "utf8")) as Catalog));
  }

  for (const t of all) {
    const cat = readCatalog(t.catalog);
    const keys = new Set(Object.keys(cat?.strings ?? {}).map(normalize));
    const mine = new Set<string>();
    used.set(t.name, mine);
    for (const file of t.files) {
      const src = readFileSync(file, "utf8");
      for (const h of scanSwift(rel(file), src, t.isPackage)) {
        const where = `${h.file}:${h.line}`;
        if (h.kind === "string") {
          if (DATA_FILE.test(`/${h.file}`) && h.form.endsWith(":")) continue;
          const why =
            h.form === "ternary of literals"
              ? "types as String; localize each branch with String(localized:)"
              : "is a String; use String(localized:) or a LocalizedStringResource";
          errs.push(`${where}: ${h.form} "${h.key.replace(/\uE000/g, "\\(..)")}" ${why}`);
          continue;
        }
        if (h.kind === "bundle") {
          errs.push(
            `${where}: ${h.form} "${h.key.replace(/\uE000/g, "\\(..)")}" in a package needs Text(.., bundle: #bundle) / String(localized:, bundle: #bundle)`,
          );
          continue;
        }
        mine.add(normalizeLiteral(h.key));
        if (!keys.has(normalizeLiteral(h.key))) {
          errs.push(
            `${where}: ${h.form} "${h.key.replace(/\uE000/g, "\\(..)")}" is not in ${rel(t.catalog)}`,
          );
        }
      }
    }
    if (cat) {
      for (const [key, entry] of Object.entries(cat.strings)) {
        if (entry.extractionState === "manual" || entry.shouldTranslate === false) continue;
        if (!mine.has(normalize(key)))
          errs.push(`${rel(t.catalog)}: "${key}" is stale (no literal in ${t.name} names it)`);
      }
    }
    for (const k of t.infoKeys) {
      const ip = readCatalog(join(dirname(t.catalog), "InfoPlist.xcstrings"));
      if (!ip?.strings[k])
        errs.push(
          `${t.name}: ${k} has no key in ${rel(join(dirname(t.catalog), "InfoPlist.xcstrings"))}`,
        );
    }
  }
  return [...new Set(errs)];
}

if (import.meta.main) {
  const root = resolve(import.meta.dir, "..");
  const errs = run(root);
  if (errs.length > 0) {
    console.error(errs.join("\n"));
    console.error(`\ncheck-strings: ${errs.length} problem${errs.length === 1 ? "" : "s"}`);
    process.exit(1);
  }
  console.log("check-strings: ok");
}
