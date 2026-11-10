import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MarkdownView } from "./Markdown";

const html = (content: string) => renderToStaticMarkup(createElement(MarkdownView, { content }));

describe("MarkdownView", () => {
  test("renders a GFM table", () => {
    const out = html("| a | b |\n|-|-|\n| 1 | 2 |\n");
    expect(out).toContain("<table>");
    expect(out).toContain("<th>a</th>");
  });

  test("raw HTML does not pass through", () => {
    const out = html('<script>alert(1)</script>\n\n<b onclick="x()">bold</b>');
    expect(out).not.toContain("<script");
    expect(out).not.toContain("<b ");
    expect(out).toContain("&lt;script&gt;");
  });

  test("a data image renders, any other image becomes its alt text", () => {
    const data = html("![dot](data:image/png;base64,AAAA)");
    expect(data).toContain('<img src="data:image/png;base64,AAAA"');
    const remote = html("![Remote picture](https://example.com/p.png)");
    expect(remote).not.toContain("<img");
    expect(remote).toContain("Remote picture");
  });

  test("links stay plain anchors and javascript: links lose their href", () => {
    expect(html("[docs](https://example.com/docs)")).toContain(
      '<a href="https://example.com/docs">docs</a>',
    );
    expect(html("[bad](javascript:alert(1))")).not.toContain("javascript:");
  });

  test("code is highlighted for a registered language only", () => {
    expect(html("```ts\nconst a: number = 1;\n```")).toContain("hljs-keyword");
    expect(html("```cobol\nMOVE 1 TO X\n```")).not.toContain("hljs-");
  });

  test("math renders through KaTeX", () => {
    expect(html("$E=mc^2$")).toContain("katex");
  });
});
