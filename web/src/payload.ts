export type Scheme = "light" | "dark";

export type Artifact =
  | { kind: "show"; spec: unknown }
  | { kind: "doc"; format: "markdown" | "html"; title?: string; content: string };

export type Theme = { scheme: Scheme; vars?: Record<string, string> };

export type Payload = { artifact: Artifact; theme: Theme };

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function parseArtifact(value: unknown): Artifact | null {
  if (!isRecord(value)) return null;
  if (value.kind === "show") return "spec" in value ? { kind: "show", spec: value.spec } : null;
  if (value.kind !== "doc") return null;
  const { format, title, content } = value;
  if (format !== "markdown" && format !== "html") return null;
  if (typeof content !== "string") return null;
  if (title !== undefined && typeof title !== "string") return null;
  return title === undefined
    ? { kind: "doc", format, content }
    : { kind: "doc", format, title, content };
}

function parseTheme(value: unknown): Theme | null {
  if (!isRecord(value)) return null;
  if (value.scheme !== "light" && value.scheme !== "dark") return null;
  const { scheme, vars } = value;
  if (vars === undefined) return { scheme };
  if (!isRecord(vars)) return null;
  const entries = Object.entries(vars);
  if (!entries.every(([, v]) => typeof v === "string")) return null;
  return { scheme, vars: Object.fromEntries(entries) as Record<string, string> };
}

/** Hand-written guard for what the host sends to `window.iris.render`; `null` = not a payload. */
export function parsePayload(value: unknown): Payload | null {
  if (!isRecord(value)) return null;
  const artifact = parseArtifact(value.artifact);
  const theme = parseTheme(value.theme);
  return artifact && theme ? { artifact, theme } : null;
}
