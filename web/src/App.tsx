import { Component, type ReactNode } from "react";
import { DocArtifact } from "./DocArtifact";
import { messages } from "./messages";
import { parsePayload, type Payload } from "./payload";
import { ShowArtifact } from "./show/ShowArtifact";
import { parseSpec } from "./spec";

export function Notice() {
  return (
    <p className="notice" role="status">
      {messages.unavailable}
    </p>
  );
}

class Boundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? <Notice /> : this.props.children;
  }
}

function Content({ payload }: { payload: Payload }) {
  const { artifact, theme } = payload;
  if (artifact.kind === "doc") return <DocArtifact artifact={artifact} />;
  const spec = parseSpec(artifact.spec);
  return spec ? <ShowArtifact spec={spec} scheme={theme.scheme} /> : <Notice />;
}

/** `payload` is the raw value the host sent; anything that is not a valid payload is the notice. */
export function App({ raw, generation }: { raw: unknown; generation: number }) {
  const payload = parsePayload(raw);
  // A new payload resets the boundary through the key.
  return (
    <Boundary key={generation}>{payload ? <Content payload={payload} /> : <Notice />}</Boundary>
  );
}
