export interface TranscriptionResult {
  text: string;
  audioSeconds: number;
  /** Absent when the downstream does not report spend (audio-gateway records it itself). */
  costUsd?: number;
}

export interface Transcriber {
  /** Joins the segments in the order given into one recording, then transcribes it. */
  transcribe(params: {
    memoId: string;
    segmentPaths: string[];
    language?: string;
  }): Promise<TranscriptionResult>;
}
