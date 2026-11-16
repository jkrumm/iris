import type { Summary } from "../memo/memo.js";

export interface Summarization {
  summary: Summary;
  usage?: unknown;
  costUsd?: number;
}

export interface Summarizer {
  /** The notification text. `replyText` is null for a memo that never reached Hermes (mode `transcribe`). */
  summarize(params: {
    memoId: string;
    route: string;
    transcript: string;
    replyText: string | null;
  }): Promise<Summarization>;
  /** One short sentence or two on what the speaker said or asked, in the transcript's language, at most `GIST_MAX` code points. */
  gist(params: { memoId: string; transcript: string }): Promise<string>;
}
