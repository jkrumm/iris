import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import IrisMac

/// The take path of the Mac app on fakes: the real `CaptureStack`, `CaptureSession`, outbox and `APIOutboxUploader`, over the
/// Core Audio route manager on a scripted device list, a placeholder-file recorder and the fake API. Only the microphone and
/// the server are fake.
@MainActor
@Suite("Mac take engine")
struct CaptureTakeEngineTests {
  private struct Rig {
    let engine: CaptureTakeEngine
    let recorder: FakeSegmentRecorder
    let devices: FakeAudioDeviceDirectory
    let api: FakeAPIClient
    let directory: URL
  }

  private func rig() -> Rig {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-mac-take-\(UUID().uuidString)")
    let recorder = FakeSegmentRecorder(directory: directory)
    let devices = FakeAudioDeviceDirectory()
    let routes = DirectoryRouteManager(directory: devices, suiteName: "iris.mac.tests.\(UUID().uuidString)")
    let api = FakeAPIClient()
    let stack = CaptureStack(
      .init(
        session: MacAudioSessionController(), routes: routes, recorder: recorder, clock: SystemCaptureClock(),
        store: InMemoryOutboxStore(), uploader: APIOutboxUploader(client: api, created: CreatedMemoLog()),
        deletesFilesWhenDone: false))
    return Rig(
      engine: CaptureTakeEngine(stack: stack, routes: routes, levels: recorder.levels), recorder: recorder,
      devices: devices, api: api, directory: directory)
  }

  private func seconds(_ value: Int) -> Int { value * 16_000 }

  @Test("a take of 12 s reaches the server as a memo with two segments, in mode auto")
  func takeReachesTheServer() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    _ = try await rig.engine.start()
    await rig.recorder.feed(frames: seconds(12))
    #expect(try await rig.engine.stop() == .queued)
    #expect(
      await eventually {
        guard let id = await rig.api.segments.keys.first else { return false }
        return (try? await rig.api.memo(id: id).memo.segmentCount) == 2
      })
    let id = await rig.api.segments.keys.first
    let memo = try await rig.api.memo(id: try #require(id)).memo
    #expect(memo.mode == .auto)
  }

  @Test("a take with no audio is dropped, not sent")
  func emptyTake() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    _ = try await rig.engine.start()
    #expect(try await rig.engine.stop() == .nothingRecorded)
    #expect(await rig.api.segments.isEmpty)
  }

  @Test("the microphone picked during a take is the default input until the take ends, then the old one is back")
  func inputIsRestored() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    _ = try await rig.engine.start()
    try await rig.engine.select(microphone: FakeAudioDeviceDirectory.usb.uid)
    #expect(rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.usb.uid)
    #expect(await rig.engine.microphones().current?.uid == FakeAudioDeviceDirectory.usb.uid)
    await rig.recorder.feed(frames: seconds(3))
    _ = try await rig.engine.stop()
    #expect(rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.builtIn.uid)
  }

  @Test("a cancelled take sends nothing and puts the input back")
  func cancelledTake() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    _ = try await rig.engine.start()
    try await rig.engine.select(microphone: FakeAudioDeviceDirectory.usb.uid)
    await rig.recorder.feed(frames: seconds(3))
    await rig.engine.cancel()
    #expect(rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.builtIn.uid)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await rig.api.segments.isEmpty)
  }

  @Test("a microphone that appears is announced")
  func microphoneChanges() async {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    var changes = rig.engine.microphoneChanges().makeAsyncIterator()
    rig.devices.setDevices([FakeAudioDeviceDirectory.usb])
    let mics = await changes.next()
    #expect(mics?.inputs.map(\.uid) == [FakeAudioDeviceDirectory.usb.uid])
  }
}
