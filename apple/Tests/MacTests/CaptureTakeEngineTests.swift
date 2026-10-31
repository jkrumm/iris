import Foundation
import IrisCapture
import IrisCore
import Synchronization
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
    let routes: DirectoryRouteManager
    let created: CreatedMemoLog
    let api: FakeAPIClient
    let directory: URL
  }

  private func rig(inputs: [InputPort]? = nil) -> Rig {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-mac-take-\(UUID().uuidString)")
    let recorder = FakeSegmentRecorder(directory: directory)
    let devices = inputs.map { FakeAudioDeviceDirectory(inputs: $0) } ?? FakeAudioDeviceDirectory()
    let routes = DirectoryRouteManager(directory: devices, suiteName: "iris.mac.tests.\(UUID().uuidString)")
    let api = FakeAPIClient()
    let created = CreatedMemoLog()
    let stack = CaptureStack(
      .init(
        session: MacAudioSessionController(), routes: routes, recorder: recorder, clock: SystemCaptureClock(),
        store: InMemoryOutboxStore(), uploader: APIOutboxUploader(client: api, created: created),
        deletesFilesWhenDone: false))
    return Rig(
      engine: CaptureTakeEngine(stack: stack, routes: routes, levels: recorder.levels, created: created),
      recorder: recorder, devices: devices, routes: routes, created: created, api: api, directory: directory)
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

  @Test("a cancelled take's memo is forgotten, so History hides it while the server delete is pending")
  func cancelledTakeIsForgotten() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    let forgotten = IDs()
    await rig.created.setForgottenHandler { id in forgotten.add(id) }
    _ = try await rig.engine.start()
    await rig.recorder.feed(frames: seconds(12))
    #expect(await eventually { await !rig.api.segments.isEmpty })  // the server has created the memo
    let id = try #require(await rig.api.segments.keys.first)
    await rig.engine.cancel()
    #expect(forgotten.all == [id])
  }

  @Test("a stop that kept only part of the take is reported as partial")
  func partialTake() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    _ = try await rig.engine.start()
    await rig.recorder.feed(frames: seconds(12))
    await rig.recorder.fail(reason: "the disk is full")
    #expect(try await rig.engine.stop() == .partial)
  }

  @Test("the waveform keeps flowing in every take, after the first take's consumer has gone")
  func levelsOverSeveralTakes() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    for _ in 1...3 {
      let stream = rig.engine.levels
      let seen = IDs()
      let consumer = Task { for await _ in stream { seen.add("level") } }
      _ = try await rig.engine.start()
      #expect(
        await eventually {
          await rig.recorder.feed(frames: seconds(1))
          return !seen.all.isEmpty
        })
      consumer.cancel()
      _ = try await rig.engine.stop()
    }
  }

  @Test("a device change reaches the panel and the capture session in every take, whichever consumer has gone")
  func deviceChangesReachBothConsumers() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    // Rule: this output uses the USB microphone. The session re-applies it when the default input moves away from it.
    await rig.routes.setRule(fingerprint: "fake-mac-speakers", preferredPortUID: FakeAudioDeviceDirectory.usb.uid)
    for _ in 1...3 {
      let panel = rig.engine.microphoneChanges()
      _ = try await rig.engine.start()
      #expect(rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.usb.uid)
      var changes = panel.makeAsyncIterator()
      try rig.devices.setDefaultInput(uid: FakeAudioDeviceDirectory.builtIn.uid)
      #expect(await changes.next()?.current?.uid != nil)
      #expect(await eventually { rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.usb.uid })
      _ = try await rig.engine.stop()
      #expect(rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.builtIn.uid)
    }
  }

  @Test("a start that fails after the session changed the input puts the input back")
  func failedStartRestoresTheInput() async throws {
    let rig = rig()
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    await rig.routes.setRule(fingerprint: "fake-mac-speakers", preferredPortUID: FakeAudioDeviceDirectory.usb.uid)
    // The recorder is busy, so the session's start throws after it applied the rule.
    try await rig.recorder.start(memoID: MemoID())
    await #expect(throws: (any Error).self) { try await rig.engine.start() }
    #expect(rig.devices.defaultInput()?.uid == FakeAudioDeviceDirectory.builtIn.uid)
  }

  @Test("a default input somebody else chose during the take is left alone")
  func foreignInputIsKept() async throws {
    let headset = InputPort(uid: "fake-mac-headset", name: "Headset", kind: .bluetoothHFP)
    let rig = rig(inputs: [FakeAudioDeviceDirectory.builtIn, FakeAudioDeviceDirectory.usb, headset])
    defer { try? FileManager.default.removeItem(at: rig.directory) }
    _ = try await rig.engine.start()
    try await rig.engine.select(microphone: FakeAudioDeviceDirectory.usb.uid)
    try rig.devices.setDefaultInput(uid: headset.uid)
    _ = try await rig.engine.stop()
    #expect(rig.devices.defaultInput()?.uid == headset.uid)
  }
}

/// Ids a handler was told, in order (the handler is called off the main actor).
private nonisolated final class IDs: Sendable {
  private let seen = Mutex<[String]>([])
  var all: [String] { seen.withLock { $0 } }
  func add(_ id: String) { seen.withLock { $0.append(id) } }
}
