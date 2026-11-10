// DEV ONLY: every fixture the harness (and the screenshots) can render.
import type { Artifact } from "../payload";

const show = import.meta.glob<unknown>("../../../contracts/fixtures/artifacts.show-spec.*.json", {
  eager: true,
  import: "default",
});
const files = import.meta.glob<string>("../../fixtures/*", {
  eager: true,
  query: "?raw",
  import: "default",
});

const baseName = (path: string) => path.split("/").pop() ?? path;

export const fixtures: Record<string, Artifact> = {};

for (const [path, spec] of Object.entries(show)) {
  const name = baseName(path)
    .replace(/^artifacts\.show-spec\./, "")
    .replace(/\.json$/, "");
  fixtures[name] = { kind: "show", spec };
}
for (const [path, content] of Object.entries(files)) {
  const file = baseName(path);
  if (file === "doc-markdown.md")
    fixtures["markdown"] = { kind: "doc", format: "markdown", title: "Release notes", content };
  if (file === "doc-html.html")
    fixtures["html"] = { kind: "doc", format: "html", title: "Styled document", content };
  if (file === "invalid-spec.json")
    fixtures["invalid-spec"] = { kind: "show", spec: JSON.parse(content) };
}
fixtures["invalid-payload"] = { kind: "show", spec: { type: "nope" } };
