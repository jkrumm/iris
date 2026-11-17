import Foundation

/// Which spoken form of a reply `GET /v1/memos/:id/speech?variant=` returns. Without a variant the server picks what shipped
/// apps and the auto-read get (``Memo``'s cleaned reply, or the spoken summary plus "details on screen" past 600 characters).
public enum SpeechVariant: String, CaseIterable, Hashable, Sendable {
  /// The `summary.spoken` line alone: a few sentences.
  case summary
  /// The whole cleaned reply (up to 12,000 characters).
  case full
}
