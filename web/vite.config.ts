import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

/**
 * The host serves flat files and runs the page as a classic script. This plugin rewrites the emitted
 * entry page: the module script becomes a plain script at the end of <body> (so `window.iris` exists
 * before the host's first `render` call), and `crossorigin` goes (it only matters for CORS fetches).
 */
function classicScript(): Plugin {
  return {
    name: "iris-classic-script",
    enforce: "post",
    transformIndexHtml(html) {
      const script = /\s*<script type="module"[^>]*\ssrc="([^"]+)"[^>]*><\/script>/;
      const src = script.exec(html)?.[1];
      if (!src) return html;
      return html
        .replace(script, "")
        .replace(/\scrossorigin(="[^"]*")?/g, "")
        .replace("</body>", `  <script src="${src}"></script>\n  </body>`);
    },
  };
}

/** KaTeX ships woff2, woff and ttf for each face; the WebViews all read woff2, so only that stays referenced. */
function katexWoff2Only(): Plugin {
  return {
    name: "iris-katex-woff2-only",
    enforce: "pre",
    transform(code, id) {
      if (!id.endsWith("katex.min.css")) return null;
      return code.replace(
        /src:url\((fonts\/[^)]+\.woff2)\) format\("woff2"\),url\([^)]+\) format\("woff"\),url\([^)]+\) format\("truetype"\)/g,
        'src:url($1) format("woff2")',
      );
    },
  };
}

// `vite build` makes the production page (index.html). `vite build --mode harness` makes the dev harness
// for the Playwright screenshots; it is never synced into the app bundle.
export default defineConfig(({ mode }) => {
  const harness = mode === "harness";
  return {
    base: "./",
    resolve: {
      alias: { lowlight: fileURLToPath(new URL("./src/doc/lowlight-lite.ts", import.meta.url)) },
    },
    plugins: [react(), katexWoff2Only(), classicScript()],
    build: {
      outDir: process.env.WEB_OUT ?? (harness ? "dist-harness" : "dist"),
      emptyOutDir: true,
      assetsDir: "",
      assetsInlineLimit: 0,
      sourcemap: false,
      cssCodeSplit: false,
      modulePreload: false,
      minify: true,
      target: "es2022",
      reportCompressedSize: false,
      rolldownOptions: {
        input: harness ? "harness.html" : "index.html",
        output: {
          format: "iife",
          inlineDynamicImports: true,
          entryFileNames: harness ? "harness.js" : "artifact.js",
          assetFileNames: (asset) =>
            asset.names.some((name) => name.endsWith(".css"))
              ? harness
                ? "harness.css"
                : "artifact.css"
              : "[name][extname]",
        },
      },
    },
  };
});
