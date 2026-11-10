import { HtmlDocView } from "./doc/HtmlDoc";
import { MarkdownView } from "./doc/Markdown";
import type { Artifact } from "./payload";

export function DocArtifact({ artifact }: { artifact: Extract<Artifact, { kind: "doc" }> }) {
  return (
    <article className={artifact.format === "markdown" ? "doc card" : "doc"}>
      {artifact.title ? <h2 className="doc-title">{artifact.title}</h2> : null}
      {artifact.format === "markdown" ? (
        <MarkdownView content={artifact.content} />
      ) : (
        <HtmlDocView content={artifact.content} title={artifact.title} />
      )}
    </article>
  );
}
