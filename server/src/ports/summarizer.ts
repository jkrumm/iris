import type { Summary } from "../memo/memo.js";

export interface Summarization {
  summary: Summary;
  usage?: unknown;
  costUsd?: number;
}

export interface Summarizer {
  summarize(params: {
    memoId: string;
    route: string;
    transcript: string;
    replyText: string | null;
  }): Promise<Summarization>;
}
