import Foundation
import IrisCore

/// Memos for the history tests: `age` is seconds before the fixed `now`, so a larger age sorts lower in the list.
nonisolated enum MemoFactory {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func memo(
    _ id: String, age: TimeInterval = 0, state: MemoState = .notified, mode: MemoMode = .auto, route: String? = nil,
    destinationRef: String? = nil, favorite: Bool = false, done: Bool = false, archived: Bool = false,
    failedStep: MemoStep? = nil, error: String? = nil, audioSeconds: Double? = nil, transcript: String? = nil,
    summary: MemoSummary? = nil
  ) -> Memo {
    let created = now.addingTimeInterval(-age)
    return Memo(
      id: id, mode: mode, device: "iphone", startedAt: created, state: state, failedStep: failedStep, error: error,
      audioSeconds: audioSeconds, transcript: transcript ?? "memo \(id)", route: route, destinationRef: destinationRef,
      summary: summary, done: done, favorite: favorite, archived: archived, createdAt: created, updatedAt: created)
  }

  static func detail(_ memo: Memo) -> MemoDetail {
    MemoDetail(memo: memo, steps: [])
  }
}
