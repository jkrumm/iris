import Foundation
import IrisCore

/// Memos for the history tests: `age` is seconds before the fixed `now`, so a larger age sorts lower in the list.
nonisolated enum MemoFactory {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func memo(
    _ id: String, age: TimeInterval = 0, state: MemoState = .notified, route: String? = nil, favorite: Bool = false,
    done: Bool = false, archived: Bool = false
  ) -> Memo {
    let created = now.addingTimeInterval(-age)
    return Memo(
      id: id, mode: .auto, device: "iphone", startedAt: created, state: state, transcript: "memo \(id)", route: route,
      done: done, favorite: favorite, archived: archived, createdAt: created, updatedAt: created)
  }

  static func detail(_ memo: Memo) -> MemoDetail {
    MemoDetail(memo: memo, steps: [])
  }
}
