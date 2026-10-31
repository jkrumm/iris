import Foundation
import IrisCapture
import IrisCore

/// The Mac's capture side, assembled once for production: the engine recorder on the system default input, the Core Audio
/// route manager, the persistent outbox in the app container and an API uploader over the Mac's saved connection.
///
/// The same `CaptureStack` and `APIOutboxUploader` as the iPhone's; what differs is only the audio side (no `AVAudioSession`)
/// and where the queue lives. The take itself is ``CaptureTakeEngine``.
struct MacCaptureStack {
  let stack: CaptureStack
  let service: OutboxService
  let engine: CaptureTakeEngine
  let created: CreatedMemoLog
  private let client: ReconfigurableAPIClient
  private let epoch: ConnectionEpoch

  /// The server the outbox's calls go to now (``ConnectionCredentials/serverKey``), `nil` without a connection: what the outbox
  /// binds new work to, and what a call made for an item checks (`WrongServerError`).
  var serverKey: String? { client.serverKey }

  /// The saved connection changed: the uploader's client points at the new server, and a create the old one is still
  /// answering is refused (see ``ConnectionBoundClient``).
  func reconnect(_ credentials: ConnectionCredentials?) {
    epoch.advance()
    client.reconfigure(credentials)
  }

  static func production(credentials: ConnectionCredentials?, log: DeviceLog, root: URL? = nil) -> MacCaptureStack {
    let client = ReconfigurableAPIClient(credentials: credentials)
    let epoch = ConnectionEpoch()
    let created = CreatedMemoLog()
    let root = root ?? URL.applicationSupportDirectory.appending(path: "Iris", directoryHint: .isDirectory)
    let captureDirectory = root.appending(path: "capture", directoryHint: .isDirectory)
    // Capture, route and outbox events go to the device log (`iris-macos`), the same records the iPhone writes.
    let events = DeviceLogCaptureEvents(log: log)
    let recorder = try? AVAudioEngineSegmentRecorder(directory: captureDirectory, events: events)
    let segmentFiles = DirectorySegmentFiles(directory: captureDirectory)
    // A kill mid-take leaves the picked microphone as the system default: the record the wrapper keeps says what to put back.
    let directory = CoreAudioDeviceDirectory()
    let inputStore = UserDefaultsInputRecoveryStore()
    let recovery = RecoveringRouteManager.recover(store: inputStore, directory: directory)
    if recovery != .none { events.event("audio.input_recovery", ["result": .string(recovery.telemetryName)]) }
    let routes = RecoveringRouteManager(DirectoryRouteManager(directory: directory), store: inputStore, events: events)
    let stack = CaptureStack(
      .init(
        session: MacAudioSessionController(), routes: routes, recorder: recorder ?? UnavailableSegmentRecorder(),
        clock: SystemCaptureClock(),
        store: JSONFileOutboxStore(fileURL: root.appending(path: "outbox.json"), segmentDirectory: captureDirectory),
        uploader: ObservedSegmentUploader(
          APIOutboxUploader(
            client: ConnectionBoundClient(base: client, epoch: epoch), created: created, keeping: segmentFiles),
          log: log),
        events: events, segmentFiles: segmentFiles,
        // Work is bound to the server it was queued under: after a switch it is held back, and a call checks it (`WrongServerError`).
        serverKey: { client.serverKey }))
    return MacCaptureStack(
      stack: stack, service: OutboxService(stack: stack, created: created),
      engine: CaptureTakeEngine(
        stack: stack, routes: routes, levels: recorder?.levels ?? AsyncStream { $0.finish() }, created: created),
      created: created, client: client, epoch: epoch)
  }
}
