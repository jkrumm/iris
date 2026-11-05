import IrisTelemetry
import IrisUI

/// The App Group snapshot store with its outcomes on the device log (TDD §8): whether the container is there at all
/// (`widget.container`, once) and whether each write landed (`widget.snapshot`, with the memo id and phase, never the
/// headline). This is how a device run shows the App Group is entitled and the feed is live.
struct LoggedLastMemoSnapshotStore: LastMemoSnapshotStoring {
  private let base: FileLastMemoSnapshotStore

  init(_ base: FileLastMemoSnapshotStore = .appGroup()) {
    self.base = base
    DeviceLog.shared.event(
      "widget.container", severity: base.isAvailable ? .info : .warn,
      ["group": .string(FileLastMemoSnapshotStore.appGroupIdentifier), "available": .bool(base.isAvailable)])
  }

  func load() -> LastMemoSnapshot? { base.load() }

  @discardableResult
  func save(_ snapshot: LastMemoSnapshot?) -> Bool {
    let saved = base.save(snapshot)
    DeviceLog.shared.event(
      "widget.snapshot", memoWireID: snapshot?.memoID, severity: saved ? .info : .warn,
      [
        "saved": .bool(saved), "cleared": .bool(snapshot == nil),
        "phase": .string(snapshot.map { "\($0.phase)" } ?? "none"),
      ])
    return saved
  }
}
