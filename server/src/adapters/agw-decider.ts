import { z } from "zod";
import type { Decider, Choice, Decision } from "../ports/decider.js";
import { log } from "../telemetry/log.js";
import type { AgwClient } from "./agw-client.js";
import { RUN_ID_ATTR } from "./audio-door-client.js";

const DESTINATION_INSTRUCTIONS =
  "A voice memo was dictated. Decide where it should go. The memo is in German or English; choose the destination whose description fits what the speaker wants.";
const TAB_INSTRUCTIONS =
  "If the memo is an instruction for a terminal coding agent, choose the open tab it is addressed to.";

const Answer = z.discriminatedUnion("type", [
  z.looseObject({
    type: z.literal("choice"),
    choice: z.string(),
    confidence: z.number().min(0).max(1),
  }),
  z.looseObject({ type: z.literal("refusal") }),
]);

const DecideResponse = z.looseObject({
  answers: z.record(z.string(), Answer),
  model: z.string(),
  usage: z.looseObject({ costUsd: z.number().nullish() }).nullish(),
});

function choiceOf(answer: z.infer<typeof Answer> | undefined): Choice | null {
  return answer?.type === "choice"
    ? { choice: answer.choice, confidence: answer.confidence }
    : null;
}

/**
 * `Decider` on the agent-workflows `decide` capability: one decision-model call, no text generation.
 * A failure throws; the route step fails and POST /retry {from: route} recovers it.
 */
export function createAgwDecider(opts: { client: AgwClient }): Decider {
  return {
    async decide({ memoId, state, destinations, tabs }): Promise<Decision> {
      const { data, runId } = await opts.client.call({
        memoId,
        path: "/decide",
        body: {
          state,
          questions: {
            destination: {
              type: "choice",
              instructions: DESTINATION_INSTRUCTIONS,
              options: destinations,
            },
            ...(tabs && {
              tab: { type: "choice", instructions: TAB_INSTRUCTIONS, options: tabs },
            }),
          },
        },
        schema: DecideResponse,
      });
      const { answers, model, usage } = data;
      log("agw.decided", { memo_id: memoId, [RUN_ID_ATTR]: runId });
      // A null cost is unpriced, not free: store none, never 0.
      const costUsd = usage?.costUsd ?? undefined;
      return {
        destination: choiceOf(answers["destination"]),
        tab: choiceOf(answers["tab"]),
        model,
        ...(usage ? { usage } : {}),
        ...(costUsd !== undefined ? { costUsd } : {}),
      };
    },
  };
}
