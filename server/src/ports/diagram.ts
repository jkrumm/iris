export interface RenderedScheme {
  /** A standalone SVG document with the scheme's colours resolved, no CSS variables left. */
  svg: string;
  /** `image/png` of the same diagram. */
  png: Uint8Array;
}

export interface RenderedDiagram {
  /** The diagram's size in points; the PNG is rendered at a multiple of it. */
  width: number;
  height: number;
  light: RenderedScheme;
  dark: RenderedScheme;
}

export interface DiagramRenderer {
  /** Renders Mermaid `source` for both colour schemes. A throw means this diagram cannot be rendered. */
  render(source: string): Promise<RenderedDiagram>;
}
