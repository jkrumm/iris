import { defaultUrlTransform } from "react-markdown";
import ReactMarkdown, { type Components, type UrlTransform } from "react-markdown";
import rehypeHighlight from "rehype-highlight";
import rehypeKatex from "rehype-katex";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import { languages } from "./languages";

const isDataImage = (url: string) => /^data:image\//i.test(url);

/** The default transform drops `data:` URLs; images may use them (nothing else loads: CSP, no network). */
const urlTransform: UrlTransform = (url, key, node) =>
  key === "src" && node.tagName === "img" && isDataImage(url) ? url : defaultUrlTransform(url);

const components: Components = {
  img({ src, alt }) {
    if (typeof src === "string" && isDataImage(src)) return <img src={src} alt={alt ?? ""} />;
    return alt ? <span className="img-alt">{alt}</span> : null;
  },
};

const remarkPlugins = [remarkGfm, remarkMath];
const rehypePlugins: NonNullable<Parameters<typeof ReactMarkdown>[0]["rehypePlugins"]> = [
  rehypeKatex,
  [rehypeHighlight, { languages, detect: false }],
];

/** Raw HTML in the source is never passed through (react-markdown default, no rehype-raw). */
export function MarkdownView({ content }: { content: string }) {
  return (
    <div className="markdown">
      <ReactMarkdown
        remarkPlugins={remarkPlugins}
        rehypePlugins={rehypePlugins}
        components={components}
        urlTransform={urlTransform}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}
