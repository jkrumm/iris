import { messages } from "../messages";
import type { CalloutSpec } from "../spec";

export function CalloutView({ spec }: { spec: CalloutSpec }) {
  return (
    <div className={`callout ${spec.tone}`}>
      <div className="callout-tone">{messages.tone[spec.tone]}</div>
      <div className="callout-body">{spec.body}</div>
    </div>
  );
}
