import { MemoError } from "../memo/errors.js";
import {
  FactoryError,
  type FactoryAnswerAck,
  type FactoryAsk,
  type FactoryHealth,
  type FactoryReader,
} from "../ports/factory.js";
import { log } from "../telemetry/log.js";

/** A decision ask of an Issue is the only kind the owner answers from here; the human queue and the rest are read-only. */
export const isDecisionAsk = (ask: Pick<FactoryAsk, "source" | "issue">) =>
  ask.source === "decision" && ask.issue !== null;

export interface FactoryView {
  asks: (FactoryAsk & { answerable: boolean; options: string[] })[];
  health: FactoryHealth[];
  counts: { asks: number; health: number };
  builtAt: string;
}

/** Maps the factory's failures onto the single `MemoError` set: `unavailable` (503), `not_found`, `bad_state` (409). */
function mapError(err: unknown): never {
  if (!(err instanceof FactoryError)) throw err;
  switch (err.code) {
    case "not_found":
      throw new MemoError("not_found", "the factory has no such Issue");
    case "conflict":
      throw new MemoError("bad_state", "the factory has no open question on this Issue");
    case "bad_request":
      throw new MemoError("bad_request", "the factory rejected the answer");
    default:
      throw new MemoError("unavailable", "the factory is unreachable");
  }
}

/** What the app sees of the factory: the asks and health line, and answers forwarded. */
export function createFactoryService(deps: { reader: FactoryReader }) {
  const { reader } = deps;

  return {
    async view(): Promise<FactoryView> {
      const overview = await reader.overview().catch(mapError);
      const asks = await Promise.all(
        overview.asks.map(async (ask) => {
          const answerable = isDecisionAsk(ask);
          // Best effort: a card without options is still answerable in free text.
          const options =
            answerable && ask.issue !== null
              ? await reader.issueQuestion(ask.issue).catch((err: unknown) => {
                  log("factory.options_failed", { issue: ask.issue, error: String(err) });
                  return [];
                })
              : [];
          return { ...ask, answerable, options };
        }),
      );
      return {
        asks,
        health: overview.health,
        counts: { asks: asks.length, health: overview.health.length },
        builtAt: overview.builtAt,
      };
    },

    /** Resolves the Issue from the ask in the factory's *current* list, so a gone ask is a 404 and never answered blind. */
    async answer(params: {
      askId: string;
      text: string;
      callId: string;
    }): Promise<FactoryAnswerAck> {
      const text = params.text.trim();
      if (text.length < 2) throw new MemoError("bad_request", "the answer is too short");
      const asks = await reader.asks().catch(mapError);
      const ask = asks.find((a) => a.id === params.askId);
      if (!ask) throw new MemoError("not_found", "the ask is gone: answered or expired");
      if (!isDecisionAsk(ask) || ask.issue === null) {
        throw new MemoError("bad_state", "this ask cannot be answered from here");
      }
      return reader.answer({ issue: ask.issue, callId: params.callId, text }).catch(mapError);
    },
  };
}

export type FactoryService = ReturnType<typeof createFactoryService>;
