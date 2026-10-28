/** Files of a memo's rendered reply blocks, one directory per memo. The rows that say which belong to the reply live in the memo store. */
export interface AssetStore {
  put(params: { memoId: string; assetId: string; bytes: Uint8Array }): Promise<void>;
  /** Null when the file does not exist. */
  read(params: { memoId: string; assetId: string }): Promise<Uint8Array | null>;
  /** Deletes the memo's files that are not in `keep`. Unknown memos are a no-op. */
  prune(params: { memoId: string; keep: ReadonlySet<string> }): Promise<void>;
  /** Deletes all of the memo's files. Unknown memos are a no-op. */
  removeAll(memoId: string): Promise<void>;
}
