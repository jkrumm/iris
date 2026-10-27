import { z } from "zod";
import type { Decider, Choice, Decision } from "../ports/decider.js";
import { createAgwJobRunner, type AgwClientOptions } from "./agw.js";

// Polling is the only tuning: the timeout is the job runner's hang guard (agent-limits), like triage.
// A failed job throws; the route step fails and POST /retry {from: route} recovers it.
const DEFAULT_POLL_INTERVAL_MS = 500;

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

const DecideResult = z.looseObject({
  answers: z.record(z.string(), Answer),
  model: z.string(),
  usage: z.looseObject({ costUsd: z.number().nullish() }).nullish(),
});

function choiceOf(answer: z.infer<typeof Answer> | undefined): Choice | null {
  return answer?.type === "choice"
    ? { choice: answer.choice, confidence: answer.confidence }
    : null;
}

export type AgwDeciderOptions = AgwClientOptions;

/** `Decider` on the agent-gateway `decide` tool: one decision-model call, no text generation. */
export function createAgwDecider(opts: AgwDeciderOptions): Decider {
  const run = createAgwJobRunner({
    pollIntervalMs: DEFAULT_POLL_INTERVAL_MS,
    ...opts,
  });
  return {
    async decide({ memoId, state, destinations, tabs }): Promise<Decision> {
      const result = await run({
        memoId,
        tool: "decide",
        params: {
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
      });
      const parsed = DecideResult.safeParse(result);
      if (!parsed.success) {
        const issues = parsed.error.issues
          .map((issue) => `${issue.path.join(".") || "result"}: ${issue.message}`)
          .join("; ");
        throw new Error(`agw decide result does not match the decision schema: ${issues}`);
      }
      const { answers, model, usage } = parsed.data;
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
