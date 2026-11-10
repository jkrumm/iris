/**
 * Height of the document frame in CSS px. The sandboxed frame has no scripts and no same-origin access,
 * so the page cannot read the document's height: the frame is a fixed, generous size (see AGENTS.md).
 */
export const HTML_DOC_HEIGHT = 480;

/** `sandbox=""` switches everything off: no scripts, no forms, no popups, no same-origin. */
export function HtmlDocView({ content, title }: { content: string; title?: string }) {
  return (
    <iframe
      className="html-doc"
      sandbox=""
      scrolling="no"
      srcDoc={content}
      title={title ?? "Document"}
      height={HTML_DOC_HEIGHT}
    />
  );
}
