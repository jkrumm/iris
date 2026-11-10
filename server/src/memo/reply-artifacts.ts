import { z } from "zod";
import { log } from "../telemetry/log.js";
import { extractFences } from "./fences.js";

/** More artifacts of one kind in a reply than this: the rest stay code blocks. */
export const MAX_ARTIFACTS = 12;

/** Raw `iris-show` fence body, in UTF-8 bytes, checked before `JSON.parse`. */
export const MAX_SHOW_BYTES = 64 * 1024;

/** `iris-doc` fence body, in UTF-8 bytes. */
export const MAX_DOC_BYTES = 200 * 1024;

const title = z.string().min(1).max(200);
const unit = z.string().max(16);
const cell = z.union([z.string(), z.number(), z.boolean(), z.null()]);

const TableSpec = z
  .strictObject({
    type: z.literal("table"),
    title: title.optional(),
    columns: z.array(z.string().min(1).max(80)).min(1).max(12),
    rows: z.array(z.array(cell)).max(200),
  })
  .superRefine((spec, ctx) => {
    for (const [i, row] of spec.rows.entries()) {
      if (row.length !== spec.columns.length) {
        ctx.addIssue({ code: "custom", path: ["rows", i], message: "row length" });
      }
    }
  });

const ChartSpec = z
  .strictObject({
    type: z.literal("chart"),
    title: title.optional(),
    kind: z.enum(["bar", "line", "area", "pie"]),
    x: z
      .array(z.union([z.string(), z.number()]))
      .min(1)
      .max(100),
    series: z
      .array(
        z.strictObject({
          name: z.string().min(1).max(80),
          values: z.array(z.number().nullable()),
        }),
      )
      .min(1)
      .max(8),
    unit: unit.optional(),
  })
  .superRefine((spec, ctx) => {
    for (const [i, series] of spec.series.entries()) {
      if (series.values.length !== spec.x.length) {
        ctx.addIssue({ code: "custom", path: ["series", i, "values"], message: "values length" });
      }
    }
    if (spec.kind === "pie" && spec.series.length !== 1) {
      ctx.addIssue({ code: "custom", path: ["series"], message: "pie series" });
    }
  });

const StatSpec = z.strictObject({
  type: z.literal("stat"),
  title: title.optional(),
  items: z
    .array(
      z.strictObject({
        label: z.string().min(1).max(80),
        value: z.union([z.string(), z.number()]),
        unit: unit.optional(),
        delta: z.number().optional(),
        hint: z.string().max(200).optional(),
      }),
    )
    .min(1)
    .max(8),
});

const ListSpec = z.strictObject({
  type: z.literal("list"),
  title: title.optional(),
  ordered: z.boolean().optional(),
  items: z
    .array(
      z.strictObject({
        text: z.string().min(1).max(500),
        detail: z.string().max(1000).optional(),
      }),
    )
    .min(1)
    .max(50),
});

const CalloutSpec = z.strictObject({
  type: z.literal("callout"),
  tone: z.enum(["info", "success", "warning", "danger"]),
  title: title.optional(),
  body: z.string().min(1).max(2000),
});

/** The body of an ```` ```iris-show ```` fence: one typed spec, unknown keys rejected (the contract the clients render). */
export const ShowSpec = z.discriminatedUnion("type", [
  TableSpec,
  ChartSpec,
  StatSpec,
  ListSpec,
  CalloutSpec,
]);
export type ShowSpec = z.infer<typeof ShowSpec>;

export type ArtifactKind = "show" | "doc";
export type DocFormat = "markdown" | "html";
export type InvalidReason = "too_large" | "bad_json" | "bad_spec" | "bad_info" | "empty";

export interface ExtractedArtifact {
  /** Position among the reply's fences of this kind, counting invalid ones. */
  index: number;
  kind: ArtifactKind;
  title: string | null;
  format: DocFormat | null;
  bytes: Uint8Array;
}

/**
 * The info string of an ```` ```iris-doc ```` fence: `key=value` pairs, a value optionally in double quotes (no escapes),
 * keys `title` (1..200 chars) and `format` (`markdown` | `html`, default `markdown`). Null: unknown or repeated key,
 * unknown format, empty title or a malformed pair.
 */
export function parseDocInfo(info: string): { title: string | null; format: DocFormat } | null {
  const pair = /([A-Za-z][A-Za-z0-9_-]*)=(?:"([^"]*)"|([^\s"]+))/y;
  const seen = new Map<string, string>();
  let pos = 0;
  while (pos < info.length) {
    if (/\s/.test(info[pos] as string)) {
      pos++;
      continue;
    }
    pair.lastIndex = pos;
    const match = pair.exec(info);
    if (!match) return null;
    const [whole, key = "", quoted, bare] = match;
    pos += whole.length;
    // A pair ends at whitespace or the end: `title="a"b` is malformed.
    if (pos < info.length && !/\s/.test(info[pos] as string)) return null;
    if (seen.has(key)) return null;
    seen.set(key, quoted ?? bare ?? "");
  }
  const keys = new Set(seen.keys());
  keys.delete("title");
  keys.delete("format");
  if (keys.size > 0) return null;
  const docTitle = seen.get("title") ?? null;
  if (docTitle !== null && !title.safeParse(docTitle).success) return null;
  const format = seen.get("format") ?? "markdown";
  if (format !== "markdown" && format !== "html") return null;
  return { title: docTitle, format };
}

/** The content type the asset route serves an artifact with. */
export function artifactContentType(params: {
  kind: ArtifactKind;
  format: DocFormat | null;
}): string {
  if (params.kind === "show") return "application/json";
  return params.format === "html" ? "text/html; charset=utf-8" : "text/markdown; charset=utf-8";
}

type Outcome =
  | { ok: true; artifact: Omit<ExtractedArtifact, "index" | "kind"> }
  | { ok: false; reason: InvalidReason; issues?: { path: string; code: string }[] };

const encoder = new TextEncoder();

function readShow(source: string): Outcome {
  if (encoder.encode(source).byteLength > MAX_SHOW_BYTES) return { ok: false, reason: "too_large" };
  let json: unknown;
  try {
    json = JSON.parse(source);
  } catch {
    return { ok: false, reason: "bad_json" };
  }
  const parsed = ShowSpec.safeParse(json);
  if (!parsed.success) {
    // Paths and codes only: zod messages can echo the offending value.
    const issues = parsed.error.issues
      .slice(0, 10)
      .map((issue) => ({ path: issue.path.join("."), code: issue.code }));
    return { ok: false, reason: "bad_spec", issues };
  }
  return {
    ok: true,
    artifact: {
      title: parsed.data.title ?? null,
      format: null,
      bytes: encoder.encode(JSON.stringify(parsed.data)),
    },
  };
}

function readDoc(info: string, source: string): Outcome {
  const parsedInfo = parseDocInfo(info);
  if (!parsedInfo) return { ok: false, reason: "bad_info" };
  const bytes = encoder.encode(source);
  if (bytes.byteLength > MAX_DOC_BYTES) return { ok: false, reason: "too_large" };
  if (source.trim() === "") return { ok: false, reason: "empty" };
  return { ok: true, artifact: { title: parsedInfo.title, format: parsedInfo.format, bytes } };
}

/** One fence's validation alone, without logging: null when it is invalid, else the title it announces. */
export function readArtifact(params: {
  kind: ArtifactKind;
  info: string;
  source: string;
}): { title: string | null } | null {
  const outcome =
    params.kind === "show" ? readShow(params.source) : readDoc(params.info, params.source);
  return outcome.ok ? { title: outcome.artifact.title } : null;
}

/**
 * The valid artifacts of a reply: its top-level `iris-show` and `iris-doc` fences (kind, then document order). An invalid
 * fence stays a code block and logs `reply.artifact_invalid`; past `MAX_ARTIFACTS` per kind the rest are ignored
 * (`reply.artifacts_capped`). Pure apart from logging.
 */
export function extractReplyArtifacts(params: {
  memoId: string;
  replyText: string;
}): ExtractedArtifact[] {
  const { memoId, replyText } = params;
  const fences = extractFences(replyText);
  const out: ExtractedArtifact[] = [];
  for (const [kind, lang] of [
    ["show", "iris-show"],
    ["doc", "iris-doc"],
  ] as const) {
    const ofKind = fences.filter((fence) => fence.lang === lang);
    if (ofKind.length > MAX_ARTIFACTS) {
      log("reply.artifacts_capped", {
        memo_id: memoId,
        kind,
        total: ofKind.length,
        cap: MAX_ARTIFACTS,
      });
    }
    for (const [index, fence] of ofKind.slice(0, MAX_ARTIFACTS).entries()) {
      const outcome = kind === "show" ? readShow(fence.source) : readDoc(fence.info, fence.source);
      if (!outcome.ok) {
        log("reply.artifact_invalid", {
          memo_id: memoId,
          kind,
          index,
          reason: outcome.reason,
          ...(outcome.issues && { issues: outcome.issues }),
        });
        continue;
      }
      out.push({ index, kind, ...outcome.artifact });
    }
  }
  return out;
}
