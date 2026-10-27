import type { OtlpExporter } from "./relay.js";

/** In-memory `OtlpExporter`: records every payload it is handed; `down` makes it reject like an unreachable collector. */
export function fakeOtlpExporter(options: { down?: boolean } = {}) {
  const sent: Array<{ signal: "traces" | "logs"; payload: object }> = [];
  const exporter: OtlpExporter & { sent: typeof sent; down: boolean } = {
    sent,
    down: options.down ?? false,
    async send(signal, payload) {
      if (exporter.down) throw new Error("collector unreachable");
      sent.push({ signal, payload });
    },
  };
  return exporter;
}
