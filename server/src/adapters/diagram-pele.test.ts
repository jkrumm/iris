import { describe, expect, it } from "bun:test";
import { PeleError } from "pele";
import { createPeleRenderer, resolveTheme } from "./diagram-pele.js";

const FLOW = "flowchart LR\n  A[Mermaid text] --> B{Decide} -->|yes| C[SVG]\n  B -->|no| D[Done]";
const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const png = (bytes: Uint8Array) => Array.from(bytes.subarray(0, 8));
/** IHDR width and height, big-endian at bytes 16 and 20. */
const pngSize = (bytes: Uint8Array) => {
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  return [view.getUint32(16), view.getUint32(20)];
};

describe("createPeleRenderer", () => {
  it("renders a flowchart to a themed svg and a 2x png per scheme, with no CSS variable left", async () => {
    const out = await createPeleRenderer().render(FLOW);

    expect(out.width).toBeGreaterThan(100);
    expect(out.height).toBeGreaterThan(50);
    for (const scheme of [out.light, out.dark]) {
      expect(scheme.svg).toStartWith("<svg");
      expect(scheme.svg).not.toContain("var(");
      expect(png(scheme.png)).toEqual(PNG_SIGNATURE);
      expect(pngSize(scheme.png)).toEqual([out.width * 2, out.height * 2]);
    }
    expect(out.light.svg).toContain("rgb(250 250 253)");
    expect(out.dark.svg).toContain("rgb(43 43 46)");
    expect(out.light.svg).not.toBe(out.dark.svg);
    expect(out.light.png).not.toEqual(out.dark.png);
  });

  it("renders a chart type that uses the series colours", async () => {
    const out = await createPeleRenderer().render('pie title Pets\n  "Dogs" : 386\n  "Cats" : 85');
    expect(out.dark.svg).not.toContain("var(");
    expect(out.dark.svg).toContain("rgb(162 195 240)");
  });

  it("rejects what Pele cannot render with a PeleError", async () => {
    const renderer = createPeleRenderer();
    await expect(renderer.render("flowchart LR\n A -->")).rejects.toBeInstanceOf(PeleError);
    await expect(renderer.render("this is not mermaid")).rejects.toMatchObject({
      code: "unsupported-diagram",
    });
  });

  it("keeps a huge diagram's png within the pixel cap", async () => {
    const nodes = Array.from({ length: 150 }, (_, i) => `N${i} --> N${i + 1}`).join("\n  ");
    const out = await createPeleRenderer().render(`flowchart LR\n  ${nodes}`);
    const [w, h] = pngSize(out.light.png) as [number, number];
    expect(Math.max(w, h)).toBeLessThanOrEqual(4096);
  });
});

describe("resolveTheme", () => {
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" style="--_a:var(--pele-bg,#fff);--_b:var(--pele-missing,rgb(1 2 3))" fill="var(--_a)"><rect stroke="var(--_b)" fill="var(--nowhere, red)"/></svg>';

  it("defines the scheme's variables on the root and substitutes nested var() with fallbacks", () => {
    const out = resolveTheme(svg, "light");
    expect(out).toContain('fill="rgb(250 250 253)"');
    expect(out).toContain('stroke="rgb(1 2 3)"');
    expect(out).toContain('fill="red"');
    expect(out).not.toContain("var(");
    expect(out).toContain("background:rgb(250 250 253)");
  });

  it("needs a root style attribute", () => {
    expect(() => resolveTheme('<svg xmlns="x"></svg>', "dark")).toThrow("no root style");
  });
});
