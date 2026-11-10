import { Validator } from "@cfworker/json-schema";
import schema from "../../contracts/schema/artifacts.show-spec.json";

export type Cell = string | number | boolean | null;
export type TableSpec = { type: "table"; title?: string; columns: string[]; rows: Cell[][] };
export type ChartSeries = { name: string; values: (number | null)[] };
export type ChartSpec = {
  type: "chart";
  title?: string;
  kind: "bar" | "line" | "area" | "pie";
  x: (string | number)[];
  series: ChartSeries[];
  unit?: string;
};
export type StatItem = {
  label: string;
  value: string | number;
  unit?: string;
  delta?: number;
  hint?: string;
};
export type StatSpec = { type: "stat"; title?: string; items: StatItem[] };
export type ListSpec = {
  type: "list";
  title?: string;
  ordered?: boolean;
  items: { text: string; detail?: string }[];
};
export type CalloutSpec = {
  type: "callout";
  tone: "info" | "success" | "warning" | "danger";
  title?: string;
  body: string;
};
export type ShowSpec = TableSpec | ChartSpec | StatSpec | ListSpec | CalloutSpec;

// The same schema file the server exports. @cfworker/json-schema interprets it without eval or
// `new Function`, which the page's CSP (no 'unsafe-eval') would forbid.
const validator = new Validator(schema as object, "2020-12", false);

/** The zod refinements JSON Schema cannot express. */
function refinementsHold(spec: ShowSpec): boolean {
  if (spec.type === "table") return spec.rows.every((row) => row.length === spec.columns.length);
  if (spec.type !== "chart") return true;
  if (spec.kind === "pie" && spec.series.length !== 1) return false;
  return spec.series.every((series) => series.values.length === spec.x.length);
}

/** The typed spec, or `null` when it breaks the contract schema or its refinements. */
export function parseSpec(value: unknown): ShowSpec | null {
  if (!validator.validate(value).valid) return null;
  const spec = value as ShowSpec;
  return refinementsHold(spec) ? spec : null;
}
