/** A recording that can be read in byte ranges: `Bun.file()` on disk, `bytesRecording` in memory. */
export interface Recording {
  readonly size: number;
  /** `end` is exclusive, like `Blob.slice`. */
  slice(start: number, end: number): Blob | Uint8Array;
}

export const bytesRecording = (bytes: Uint8Array): Recording => ({
  size: bytes.byteLength,
  slice: (start, end) => bytes.slice(start, end),
});

export interface AudioStore {
  /** Atomic: a reader sees the previous bytes or the new ones, never a partial file. */
  put(params: { id: string; index: number; bytes: Uint8Array }): Promise<void>;
  path(params: { id: string; index: number }): string;
  /** Drops one segment file (a write whose row was refused). Unknown ones are a no-op. */
  removeSegment(params: { id: string; index: number }): Promise<void>;
  /** Drops every segment of a memo, and its combined recording. Unknown ids are a no-op. */
  remove(id: string): Promise<void>;
  /** The cached combined recording, or null when none was stored yet. */
  readCombined(id: string): Promise<Recording | null>;
  /** Atomic like `put`. */
  putCombined(params: { id: string; bytes: Uint8Array }): Promise<void>;
}

/** Joins the segment files, in the order given, into one playable recording (audio/mp4). */
export interface AudioCombiner {
  combine(segmentPaths: string[]): Promise<Uint8Array>;
}
