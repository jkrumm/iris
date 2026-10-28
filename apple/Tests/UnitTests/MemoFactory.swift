import Foundation
import IrisCore

/// Memos for the history tests: `age` is seconds before the fixed `now`, so a larger age sorts lower in the list.
nonisolated enum MemoFactory {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func memo(
    _ id: String, age: TimeInterval = 0, state: MemoState = .notified, mode: MemoMode = .auto, route: String? = nil,
    destinationRef: String? = nil, favorite: Bool = false, done: Bool = false, archived: Bool = false,
    failedStep: MemoStep? = nil, error: String? = nil, audioSeconds: Double? = nil, transcript: String? = nil,
    summary: MemoSummary? = nil, replyText: String? = nil, typed: Bool = false
  ) -> Memo {
    let created = now.addingTimeInterval(-age)
    return Memo(
      id: id, mode: mode, device: "iphone", startedAt: created, state: state, failedStep: failedStep, error: error,
      audioSeconds: audioSeconds, transcript: transcript ?? "memo \(id)", route: route, destinationRef: destinationRef,
      replyText: replyText, summary: summary, isTyped: typed, done: done, favorite: favorite, archived: archived,
      createdAt: created, updatedAt: created)
  }

  static func detail(_ memo: Memo, steps: [StepEntry] = []) -> MemoDetail {
    MemoDetail(memo: memo, steps: steps)
  }

  /// A finished step `offset` seconds after `now` that ran `seconds`.
  static func step(
    _ step: MemoStep, at offset: TimeInterval, for seconds: TimeInterval, cost: Double? = nil,
    status: StepStatus = .done, attempts: Int = 1, error: String? = nil
  ) -> StepEntry {
    let start = now.addingTimeInterval(offset)
    return StepEntry(
      step: step, status: status, startedAt: start,
      finishedAt: status == .running ? nil : start.addingTimeInterval(seconds),
      error: error, costUsd: cost, attempts: attempts)
  }
}
