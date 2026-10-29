import { z } from "zod";
import type { Summarization, Summarizer } from "../ports/summarizer.js";
import { log } from "../telemetry/log.js";
import type { AgwClient } from "./agw-client.js";
import { RUN_ID_ATTR } from "./audio-door-client.js";

const HEADLINE_MAX = 60;
const DETAIL_MAX = 240;
// "At most two sentences" is enforced as a length cap rather than by counting sentences.
const SPOKEN_MAX = 300;

const SummarySchema = z.object({
  headline: z.string().min(1).max(HEADLINE_MAX),
  detail: z.string().max(DETAIL_MAX),
  spoken: z.string().min(1).max(SPOKEN_MAX),
});

/** The flat `POST /triage` answer: the summary plus the call's bookkeeping. `costUsd` is null when any attempt was unpriced. */
const TriageResponse = SummarySchema.extend({
  usage: z.looseObject({ costUsd: z.number().nullish() }).nullish(),
});

/**
 * `Summarizer` on the agent-workflows `triage` capability. The host owns the prompt and the 4000-character
 * cut of transcript and reply, so the raw fields go over whole.
 */
export function createAgwSummarizer(opts: { client: AgwClient }): Summarizer {
  return {
    async summarize({ memoId, route, transcript, replyText }): Promise<Summarization> {
      const { data, runId } = await opts.client.call({
        memoId,
        path: "/triage",
        body: { destination: route, transcript, reply: replyText },
        schema: TriageResponse,
      });
      const { usage, ...summary } = data;
      log("agw.triaged", { memo_id: memoId, [RUN_ID_ATTR]: runId });
      // A null cost is unpriced, not free: store none, never 0.
      const costUsd = usage?.costUsd ?? undefined;
      return {
        summary,
        ...(usage ? { usage } : {}),
        ...(costUsd !== undefined ? { costUsd } : {}),
      };
    },
  };
}
