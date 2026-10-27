export interface Speech {
  /** `audio/mpeg`. */
  bytes: Uint8Array;
  /** Absent when the downstream does not report spend (audio-gateway records it itself). */
  costUsd?: number;
}

export interface Speaker {
  /** Synthesizes `text` as mp3. A throw is a failed synthesis; the caller may retry. */
  speak(params: { memoId: string; text: string }): Promise<Speech>;
}

/** Disk cache of synthesized speech. An entry is only valid for the text it was made from. */
export interface SpeechCache {
  /** Null when absent or cached for different text (the memo was retried). */
  get(params: { memoId: string; text: string }): Promise<Uint8Array | null>;
  put(params: { memoId: string; text: string; bytes: Uint8Array }): Promise<void>;
}
