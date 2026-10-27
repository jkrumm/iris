export interface AudioStore {
  /** Atomic: a reader sees the previous bytes or the new ones, never a partial file. */
  put(params: { id: string; index: number; bytes: Uint8Array }): Promise<void>;
  path(params: { id: string; index: number }): string;
  /** Drops every segment of a memo. Unknown ids are a no-op. */
  remove(id: string): Promise<void>;
}
