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

  /// The saved connection changed: the uploader's client points at the new server, and a create the old one is still
  /// answering is refused (see ``ConnectionBoundClient``).
  func reconnect(_ credentials: ConnectionCredentials?) {
    epoch.advance()
    client.reconfigure(credentials)
  }

  static func production(credentials: ConnectionCredentials?, root: URL? = nil) -> MacCaptureStack {
    let client = ReconfigurableAPIClient(credentials: credentials)
    let epoch = ConnectionEpoch()
    let created = CreatedMemoLog()
    let root = root ?? URL.applicationSupportDirectory.appending(path: "Iris", directoryHint: .isDirectory)
    let captureDirectory = root.appending(path: "capture", directoryHint: .isDirectory)
    let recorder = try? AVAudioEngineSegmentRecorder(directory: captureDirectory)
    let segmentFiles = DirectorySegmentFiles(directory: captureDirectory)
    let routes = DirectoryRouteManager(directory: CoreAudioDeviceDirectory())
    let stack = CaptureStack(
      .init(
        session: MacAudioSessionController(), routes: routes, recorder: recorder ?? UnavailableSegmentRecorder(),
        clock: SystemCaptureClock(),
        store: JSONFileOutboxStore(fileURL: root.appending(path: "outbox.json"), segmentDirectory: captureDirectory),
        uploader: APIOutboxUploader(
          client: ConnectionBoundClient(base: client, epoch: epoch), created: created, keeping: segmentFiles),
        segmentFiles: segmentFiles))
    return MacCaptureStack(
      stack: stack, service: OutboxService(stack: stack, created: created),
      engine: CaptureTakeEngine(
        stack: stack, routes: routes, levels: recorder?.levels ?? AsyncStream { $0.finish() }, created: created),
      created: created, client: client, epoch: epoch)
  }
}
