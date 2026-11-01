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
 *  4. in a Swift package: a keyed literal that is not `Text(_, bundle: #bundle)` / `String(localized:, bundle: #bundle)`: a
 *     bare `Button("..")`, `.accessibilityLabel("..")` or `Text("..")` there looks in the app's bundle and shows English.
 *  5. `NS*UsageDescription` in a target's Info.plist properties without a translated `InfoPlist.xcstrings` key.
 *  6. `Text("a" + "b")` and the like: a concatenation is a `String`, which SwiftUI never looks up.
 *
 * Format specifiers are compared per argument index, with type and length modifier (`%lld` is not `%d`, `%1$@ %2$lld` is
 * not `%lld %@`), on every leaf of a plural / device variation; a German plural needs `one` and `other`. A `one` leaf may
 * drop an argument ("Eine Datei"), no leaf may add one or change a type.
 *
 * Limits (honest): a lexer, not a type checker. An interpolation's type is known only for an integer / float / string
 * literal, `.count`, `Int(..)` / `Double(..)` / `String(..)`, `.formatted(..)`, and a name declared once in the same file with
 * a plain type (`count: Int`); any other expression is accepted against a key of any type, so `\(someCall())` can pass
 * against `%@` when the runtime wants `%lld` (the catalog entry is then missing at run time, never a crash). It sees literals at the call site only, so a `String` built elsewhere and
 * passed to `Text(variable)` is invisible; a literal with no letter is data; `Text(verbatim:)` is data; a view init this
 * script does not know is not checked (extend `VIEW_INITS`). Telemetry, logs and accessibility identifiers are not
 * user-facing and are not matched. Escape hatch for a literal that is really data: `// l10n:ignore <why>` on its line or
 * the line above; `// l10n:bundle-ok <why>` there accepts a package literal whose `bundle:` is a parameter, not `#bundle`.
 * A package `bundle:` is accepted only as `#bundle`, `.module` or `Bundle.module` on the call's own argument list. `#Preview` bodies are skipped.
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
  /** Per interpolation: its class when the source tells (`int`, `float`, `obj`), else null. */
  types: (ArgClass | null)[];
};
export type ArgClass = "int" | "float" | "obj";

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
  /** The source of each `\(..)` interpolation, in order. */
  interps: string[];
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
    const interps: string[] = [];
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
        interps.push(src.slice(innerStart, i - 1).trim());
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
      interps,
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

const CLASS_OF_TYPE: Record<string, ArgClass> = {
  Int: "int",
  Int8: "int",
  Int16: "int",
  Int32: "int",
  Int64: "int",
  UInt: "int",
  UInt8: "int",
  UInt16: "int",
  UInt32: "int",
  UInt64: "int",
  Double: "float",
  Float: "float",
  CGFloat: "float",
  TimeInterval: "float",
  String: "obj",
  Substring: "obj",
};

/** Names the file declares with exactly one plain type (`count: Int`): name -> class. Any other type poisons the name. */
function declaredClasses(src: string): Map<string, ArgClass> {
  const seen = new Map<string, Set<ArgClass | "other">>();
  for (const m of src.matchAll(/\b([A-Za-z_]\w*)\s*:\s*([A-Z]\w*)/g)) {
    const name = m[1] ?? "";
    seen.set(name, (seen.get(name) ?? new Set()).add(CLASS_OF_TYPE[m[2] ?? ""] ?? "other"));
  }
  for (const m of src.matchAll(/\b(?:let|var)\s+([A-Za-z_]\w*)\s*=\s*([^\n]+)/g)) {
    const name = m[1] ?? "";
    seen.set(
      name,
      (seen.get(name) ?? new Set()).add(classify(m[2]?.trim() ?? "", new Map()) ?? "other"),
    );
  }
  const out = new Map<string, ArgClass>();
  for (const [name, set] of seen) {
    const only = set.size === 1 ? [...set][0] : undefined;
    if (only && only !== "other") out.set(name, only);
  }
  return out;
}

/** The class of an interpolated expression when the source tells, else null (see the header's limits). */
export function classify(expr: string, declared: Map<string, ArgClass>): ArgClass | null {
  if (/^-?\d+$/.test(expr) || expr.endsWith(".count") || /^U?Int\d*\(/.test(expr)) return "int";
  if (/^-?\d*\.\d+$/.test(expr) || /^(Double|Float|CGFloat)\(/.test(expr)) return "float";
  if (expr.startsWith('"') || expr.startsWith("String(") || /\.formatted\(/.test(expr))
    return "obj";
  const name = /^(?:self\.)?([A-Za-z_]\w*)$/.exec(expr)?.[1];
  return name ? (declared.get(name) ?? null) : null;
}

/** The labelled arguments of one call, top level only: `(a, bundle: #bundle, f(x: 1))` -> `{bundle: "#bundle"}`. `callText` has strings blanked. */
export function ownArgs(callText: string): Map<string, string> {
  const out = new Map<string, string>();
  let depth = 0;
  let from = 1;
  const take = (to: number) => {
    const m = /^\s*([A-Za-z_]\w*)\s*:\s*([\s\S]*?)\s*$/.exec(callText.slice(from, to));
    if (m) out.set(m[1] ?? "", m[2] ?? "");
    from = to + 1;
  };
  for (let i = 1; i < callText.length - 1; i++) {
    const c = callText[i];
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") depth--;
    else if (c === "," && depth === 0) take(i);
  }
  take(callText.length - 1);
  return out;
}

/** The only bundles a package may name: its own. Anything else (`.main`, a nested call's) looks elsewhere. */
const OWN_BUNDLE = /^(#bundle|\.module|Bundle\.module)$/;

/** The hits of one Swift file. `inPackage`: bare `Text("x")` would look in the app's bundle. */
export function scanSwift(file: string, src: string, inPackage: boolean): Hit[] {
  const { literals, text } = lex(src);
  const lines = src.split("\n");
  const hits: Hit[] = [];
  const declared = declaredClasses(src);
  for (const lit of literals) {
    if (lit.stack.some((f) => f.preview)) continue;
    if (!hasLetter(lit.value)) continue;
    const line = lineOf(src, lit.start);
    const ignored =
      /l10n:ignore/.test(lines[line - 1] ?? "") || /l10n:ignore/.test(lines[line - 2] ?? "");
    if (ignored) continue;
    const types = lit.interps.map((e) => classify(e, declared));
    const add0 = (kind: Hit["kind"], form: string) =>
      hits.push({ file, line, key: lit.value, kind, form, types });
    if (
      lit.resourceDecl ||
      (lit.stack.some((f) => f.resource) && !lit.stack.some((f) => f.open === "(" && f.callee))
    ) {
      // a bare literal cannot name a bundle, so in a package it always looks in the app's
      add0(inPackage ? "bundle" : "keyed", "LocalizedStringResource");
      continue;
    }
    const top = lit.stack[lit.stack.length - 1];
    if (!top || top.open !== "(") continue;
    const callee = top.callee;
    const own = ownArgs(text.slice(top.start, (top.close ?? top.start) + 1));
    const add = (kind: Hit["kind"], form: string) =>
      hits.push({ file, line, key: lit.value, kind, form, types });
    // `"a" + "b"` is a String
    const concat =
      /^\s*\+(?![+=])/.test(src.slice(lit.end, lit.end + 8)) ||
      /(?<![+])\+\s*$/.test(src.slice(Math.max(0, lit.start - 8), lit.start));
    // `// l10n:bundle-ok <why>`: the bundle is a parameter the caller fills with `#bundle` (a test picks a language's .lproj)
    const bundleMarked = /l10n:bundle-ok/.test(`${lines[line - 1] ?? ""}${lines[line - 2] ?? ""}`);
    const bundleOk = bundleMarked || OWN_BUNDLE.test(own.get("bundle") ?? "");
    // `comment:` and `tableName:` exist only on the `LocalizedStringKey` overloads, so they force the localizing init
    const localizing = ["bundle", "comment", "tableName"].some((l) => own.has(l));

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
    if (
      concat &&
      (lit.first || lit.label === "title" || lit.label === "label") &&
      (VIEW_INITS.has(callee) || MODIFIERS.has(callee))
    ) {
      add("string", "concatenated literals");
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
      // only Text takes a bundle: any other init or modifier looks in the app's bundle, so inside a package its
      // literal must be a String(localized:, bundle:) instead
      add(inPackage && !(callee === "Text" && bundleOk) ? "bundle" : "keyed", `${callee}(..)`);
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
  /%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(ll|l|h|hh|z|j|t|q)?([@dDuUxXoOfeEgGcCsSpaAF])|%#@\w+@/g;

/**
 * A catalog key with every format specifier as one marker (`\uE000`) and `%%` as `\uE001`, so a source literal
 * (`normalizeLiteral`) with `\(n)` interpolations and a plain `%` compares equal to its key (`%lld`, `%%`). The marker
 * carries no type: `specs` and `classOf` do.
 */
export const normalize = (key: string) => key.replace(/%%/g, "\uE001").replace(SPEC, "\uE000");
export const normalizeLiteral = (value: string) => value.replace(/%/g, "\uE001");

/** Argument index (1-based) -> type with its length modifier (`lld`, `@`, `f`), `%lf` read as `%f`. Substitutions are skipped. */
export const specs = (value: string): Map<number, string> => specsOf(value).byIndex;

/** `specs` plus the argument indexes given two different types (`%1$@ %1$lld`): the later one would overwrite the earlier. */
export function specsOf(value: string): { byIndex: Map<number, string>; conflicts: number[] } {
  const byIndex = new Map<number, string>();
  const conflicts: number[] = [];
  let next = 1;
  for (const m of value.replace(/%%/g, "").matchAll(SPEC)) {
    if (m[0].startsWith("%#@")) continue;
    const index = m[1] ? Number(m[1]) : next++;
    const type = `${m[2] ?? ""}${m[3]}`.replace(/^lf$/, "f");
    if (byIndex.has(index) && byIndex.get(index) !== type) conflicts.push(index);
    byIndex.set(index, type);
  }
  return { byIndex, conflicts };
}

/** The class a catalog type stands for, to compare with what the source interpolates. */
const classOf = (t: string): ArgClass | "other" =>
  /[dDuUxXoO]$/.test(t)
    ? "int"
    : /[fFeEgGaA]$/.test(t)
      ? "float"
      : /[@sSc]$/.test(t)
        ? "obj"
        : "other";

/** What is wrong with `got` (a translation's specifiers) against `want` (the key's); `allowOmit`: a plural `one` may drop arguments. */
function specProblem(
  want: Map<number, string>,
  got: Map<number, string>,
  allowOmit: boolean,
): string | null {
  const show = (m: Map<number, string>) =>
    [...m]
      .toSorted((x, y) => x[0] - y[0])
      .map(([i, t]) => `${i}:%${t}`)
      .join(" ") || "none";
  for (const [i, t] of got)
    if (want.get(i) !== t) return `argument ${show(got)}, the key has ${show(want)}`;
  if (!allowOmit && got.size !== want.size)
    return `argument ${show(got)}, the key has ${show(want)}`;
  return null;
}

type Node = { stringUnit?: Unit; variations?: Record<string, Record<string, Node>> };

/** Every translated leaf of a localization: `[path, unit]`; `problems` gets a plural node without `one` or `other`. */
function leaves(loc: Node | undefined, problems: string[], path = ""): [string, Unit][] {
  if (!loc) return [];
  if (loc.stringUnit) return [[path || "value", loc.stringUnit]];
  const out: [string, Unit][] = [];
  for (const [kind, cases] of Object.entries(loc.variations ?? {})) {
    if (kind === "plural") {
      for (const need of ["one", "other"])
        if (!cases[need]) problems.push(`${path || "de"} plural has no "${need}" case`);
    }
    if (Object.keys(cases).length === 0) problems.push(`${path}${kind} has no cases`);
    for (const [name, sub] of Object.entries(cases)) {
      if (!sub.stringUnit && Object.keys(sub.variations ?? {}).length === 0)
        problems.push(`${path}${kind}.${name} is empty`);
      out.push(...leaves(sub, problems, `${path}${kind}.${name}.`));
    }
  }
  return out;
}

export function checkCatalog(file: string, cat: Catalog): string[] {
  const errs: string[] = [];
  for (const [key, entry] of Object.entries(cat.strings)) {
    if (entry.shouldTranslate === false) continue;
    const problems: string[] = [];
    const lv = leaves(entry.localizations?.["de"] as Node | undefined, problems);
    if (lv.length === 0) {
      errs.push(`${file}: "${key}" has no de translation`);
      continue;
    }
    for (const p of problems) errs.push(`${file}: "${key}" de ${p}`);
    // the compiler extracts `%lld of %lld`, never `%1$lld of %2$lld`: a positional key is never looked up
    if (/%\d+\$/.test(key))
      errs.push(
        `${file}: "${key}" is a positional key; the source lookup is sequential (use %lld, not %1$lld)`,
      );
    const keySpecs = specsOf(key);
    for (const i of keySpecs.conflicts)
      errs.push(`${file}: "${key}" gives argument ${i} two types`);
    const want = keySpecs.byIndex;
    for (const [path, unit] of lv) {
      if (unit.state !== "translated" || !unit.value) {
        errs.push(`${file}: "${key}" de ${path} is ${unit.state ?? "missing"} (need translated)`);
        continue;
      }
      if (unit.value.includes("%#@")) continue; // a substitution: its own variations carry the specifiers
      const got = specsOf(unit.value);
      for (const i of got.conflicts)
        errs.push(`${file}: "${key}" de ${path} gives argument ${i} two types`);
      const bad = specProblem(want, got.byIndex, path.endsWith("plural.one."));
      if (bad) errs.push(`${file}: "${key}" de ${path === "value" ? "value" : path} has ${bad}`);
    }
    if (entry.extractionState === "stale") errs.push(`${file}: "${key}" is marked stale`);
  }
  return errs;
}

/** Catalog keys by marker shape; each holds the class of every argument by index, to check an interpolation against. */
export function keyIndex(cat: Catalog | null): Map<string, (ArgClass | "other")[][]> {
  const out = new Map<string, (ArgClass | "other")[][]>();
  for (const key of Object.keys(cat?.strings ?? {})) {
    const byIndex = [...specs(key)].toSorted((x, y) => x[0] - y[0]).map(([, t]) => classOf(t));
    const shape = normalize(key);
    out.set(shape, [...(out.get(shape) ?? []), byIndex]);
  }
  return out;
}

/** Does some key of this shape take the argument classes the source interpolates? Unknown (null) matches any. */
export const typesFit = (candidates: (ArgClass | "other")[][], types: (ArgClass | null)[]) =>
  candidates.some((c) => types.every((t, i) => t === null || c[i] === t));

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
    const keys = keyIndex(cat);
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
              : h.form === "concatenated literals"
                ? "is a String, not a key; write one literal"
                : "is a String; use String(localized:) or a LocalizedStringResource";
          errs.push(`${where}: ${h.form} "${h.key.replace(/\uE000/g, "\\(..)")}" ${why}`);
          continue;
        }
        if (h.kind === "bundle") {
          errs.push(
            `${where}: ${h.form} "${h.key.replace(/\uE000/g, "\\(..)")}" in a package looks in the app's bundle; use Text(.., bundle: #bundle) or String(localized:, bundle: #bundle)`,
          );
          continue;
        }
        const shape = normalizeLiteral(h.key);
        mine.add(shape);
        const candidates = keys.get(shape);
        const shown = h.key.replace(/\uE000/g, "\\(..)");
        if (!candidates) errs.push(`${where}: ${h.form} "${shown}" is not in ${rel(t.catalog)}`);
        else if (!typesFit(candidates, h.types))
          errs.push(
            `${where}: ${h.form} "${shown}" interpolates [${h.types.map((x) => x ?? "?").join(", ")}], the key in ${rel(t.catalog)} takes [${candidates.map((c) => c.join(", ")).join(" | ")}]`,
          );
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
