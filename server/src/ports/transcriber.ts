export interface TranscriptionResult {
  text: string;
  audioSeconds: number;
  /** Absent when the downstream does not report spend (audio-gateway records it itself). */
  costUsd?: number;
  /** `costUsd` is a price-table estimate (`memo/pricing.ts`), not a cost the downstream reported. */
  costEstimated?: boolean;
  /** The recording the transcriber built from the segments (mono 16 kHz m4a, what `AudioCombiner` makes): the caller stores it so playback needs no second concat. */
  recording?: Uint8Array;
}

export interface Transcriber {
  /** Joins the segments in the order given into one recording, then transcribes it. */
  transcribe(params: {
    memoId: string;
    segmentPaths: string[];
    language?: string;
  }): Promise<TranscriptionResult>;
}
