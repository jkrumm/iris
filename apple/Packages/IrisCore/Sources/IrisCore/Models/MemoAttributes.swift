#if canImport(ActivityKit) && !os(macOS)
  import ActivityKit
  import Foundation

  /// The Live Activity of one take, shared by the app (which starts and updates it) and the widget extension
  /// (which renders it). The static part is fixed at start; everything that changes rides in `ContentState`.
  public struct MemoAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = LiveActivityContentState

    public var memoId: String
    public var mode: MemoMode
    public var startedAt: Date
    /// Which server the memo lives on (a short digest of its URL, not the URL), so a later server-URL switch does not take that
    /// server's 404 for "memo gone". `nil` for activities started before the field existed.
    public var serverKey: String?

    public init(memoId: String, mode: MemoMode, startedAt: Date, serverKey: String? = nil) {
      self.memoId = memoId
      self.mode = mode
      self.startedAt = startedAt
      self.serverKey = serverKey
    }
  }
#endif
