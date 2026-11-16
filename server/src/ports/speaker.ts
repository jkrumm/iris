import type { SpeechVariant } from "../memo/speech-text.js";

export interface Speech {
  /** `audio/mpeg`. */
  bytes: Uint8Array;
  /** Absent when the downstream does not report spend (audio-gateway records it itself). */
  costUsd?: number;
}

export interface Speaker {
  /**
   * Synthesizes `text` as mp3, in as many calls to the downstream as its input limit needs. A throw is a failed
   * synthesis; the caller may retry.
   */
  speak(params: { memoId: string; text: string }): Promise<Speech>;
}

/**
 * Disk cache of synthesized speech, one entry per memo and variant (`undefined` is the entry of a request that names
 * none). An entry is only valid for the text it was made from.
 */
export interface SpeechCache {
  /** Null when absent or cached for different text (the memo was retried). */
  get(params: {
    memoId: string;
    variant?: SpeechVariant | undefined;
    text: string;
  }): Promise<Uint8Array | null>;
  put(params: {
    memoId: string;
    variant?: SpeechVariant | undefined;
    text: string;
    bytes: Uint8Array;
  }): Promise<void>;
  /** Drops every entry of the memo. Unknown ids are a no-op. */
  remove(memoId: string): Promise<void>;
}
