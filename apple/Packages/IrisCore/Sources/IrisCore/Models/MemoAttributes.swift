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

    public init(memoId: String, mode: MemoMode, startedAt: Date) {
      self.memoId = memoId
      self.mode = mode
      self.startedAt = startedAt
    }
  }
#endif
