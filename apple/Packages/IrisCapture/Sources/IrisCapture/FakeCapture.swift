import Foundation

/// Fake capture for UI tests and screenshots (`-IrisFakeCapture`, TDD §9) and for the package tests.
/// No microphone: a script drives frames, route changes and interruptions, and segment files are
/// small deterministic placeholders written to a directory.

public actor FakeAudioSessionController: AudioSessionController {
  public nonisolated let interruptions: AsyncStream<InterruptionEvent>
  private let continuation: AsyncStream<InterruptionEvent>.Continuation
  public private(set) var isConfigured = false
  public private(set) var isActive = false
  public private(set) var configureCount = 0
  public private(set) var activationCount = 0
  private var failingActivations = 0

  public init() {
    (interruptions, continuation) = AsyncStream.makeStream(of: InterruptionEvent.self)
  }

  public func configure() {
    isConfigured = true
    configureCount += 1
  }

  public func activate() throws {
    if failingActivations > 0 {
      failingActivations -= 1
      throw CaptureError.sessionFailure("session could not be activated")
    }
    isActive = true
    activationCount += 1
  }

  /// Script hook: the next `count` activations throw (the session is not ready right after an interruption).
  public func failActivations(_ count: Int) { failingActivations = count }
  public func deactivate() { isActive = false }

  /// Script hook: deliver an interruption event to the consumer.
  public func deliver(_ event: InterruptionEvent) {
    continuation.yield(event)
  }
}

public actor FakeRouteManager: RouteManager {
  public nonisolated let routeChanges: AsyncStream<RouteChange>
  private let continuation: AsyncStream<RouteChange>.Continuation
  private var route: RouteSnapshot
  private var storedRules: [String: String] = [:]

  public static let builtInMic = InputPort(uid: "fake-builtin-mic", name: "iPhone Microphone", kind: .builtInMic)
  public static let headsetMic = InputPort(uid: "fake-headset-mic", name: "Fake Headset", kind: .bluetoothHFP)

  public init(
    inputs: [InputPort] = [FakeRouteManager.builtInMic, FakeRouteManager.headsetMic],
    outputUIDs: [String] = ["fake-speaker"], outputNames: [String] = ["iPhone Speaker"]
  ) {
    (routeChanges, continuation) = AsyncStream.makeStream(of: RouteChange.self)
    route = RouteSnapshot(
      availableInputs: inputs, currentInput: inputs.first, outputUIDs: outputUIDs, outputNames: outputNames)
  }

  public func currentRoute() -> RouteSnapshot { route }

  public func setPreferredInput(uid: String?) throws {
    let target: InputPort?
    if let uid {
      guard let port = route.availableInputs.first(where: { $0.uid == uid }) else {
        throw CaptureError.inputUnavailable(uid: uid)
      }
      target = port
    } else {
      target = route.availableInputs.first
    }
    guard target != route.currentInput else { return }
    route = RouteSnapshot(
      availableInputs: route.availableInputs, currentInput: target, outputUIDs: route.outputUIDs,
      outputNames: route.outputNames)
    continuation.yield(RouteChange(snapshot: route, reason: .userSelection))
  }

  public func rules() -> [String: String] { storedRules }

  public func setRule(fingerprint: String, preferredPortUID: String?) {
    storedRules[fingerprint] = preferredPortUID
  }

  /// Script hook: a device appears or disappears.
  public func setAvailable(
    inputs: [InputPort], outputUIDs: [String], outputNames: [String] = [], reason: RouteChangeReason
  ) {
    let current = route.currentInput.flatMap { inputs.contains($0) ? $0 : nil } ?? inputs.first
    route = RouteSnapshot(
      availableInputs: inputs, currentInput: current, outputUIDs: outputUIDs, outputNames: outputNames)
    continuation.yield(RouteChange(snapshot: route, reason: reason))
  }
}

/// Writes placeholder segment files: 16 header bytes plus `bytesPerSecond` deterministic bytes per second.
public actor FakeSegmentRecorder: SegmentRecorder {
  public nonisolated let events: AsyncStream<CaptureEvent>
  public nonisolated let levels: AsyncStream<Float>
  public static let bytesPerSecond = 100
  public static let headerLength = 16

  private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
  private let levelContinuation: AsyncStream<Float>.Continuation
  private let directory: URL
  private let policy: SegmentRotationPolicy
  private var rotator: SegmentRotator
  private var memoID: MemoID?
  private var isPaused = false
  private var resumeFailure: String?

  public init(directory: URL, policy: SegmentRotationPolicy = SegmentRotationPolicy()) {
    self.directory = directory
    self.policy = policy
    rotator = SegmentRotator(policy: policy)
    (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self)
    (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
  }

  public func start(memoID: MemoID) throws {
    guard self.memoID == nil else { throw CaptureError.alreadyRecording }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.memoID = memoID
    rotator = SegmentRotator(policy: policy)
    isPaused = false
    eventContinuation.yield(.started(memoID))
  }

  /// Script hook: the "microphone" delivered `frames` frames. Ignored while paused or stopped.
  public func feed(frames: Int) {
    guard memoID != nil, !isPaused else { return }
    apply(rotator.append(frames: frames))
    levelContinuation.yield(0.5)
  }

  /// Script hook: the recorder reports a failure (a full disk, an engine that will not restart).
  public func fail(reason: String) {
    eventContinuation.yield(.failed(reason: reason))
  }

  public func stop() throws {
    guard let memoID else { throw CaptureError.notRecording }
    apply(rotator.finish())
    eventContinuation.yield(.stopped(memoID, segmentCount: rotator.closedCount))
    self.memoID = nil
  }

  public func rotate(for reason: RotationReason) {
    guard memoID != nil else { return }
    apply(rotator.rotate(for: reason))
  }

  public func pause() {
    guard memoID != nil, !isPaused else { return }
    apply(rotator.rotate(for: .interruption))
    isPaused = true
  }

  /// Script hook: the next `resume()` fails like an engine that will not restart.
  public func failNextResume(reason: String) {
    resumeFailure = reason
  }

  public func resume() {
    if let reason = resumeFailure {
      resumeFailure = nil
      eventContinuation.yield(.failed(reason: reason))
      return
    }
    isPaused = false
  }

  private func apply(_ actions: [SegmentAction]) {
    guard let memoID else { return }
    for action in actions {
      guard case .close(let index, let frames, let reason) = action else { continue }
      do {
        let data = Self.placeholderData(memoID: memoID, index: index, duration: policy.duration(frames: frames))
        let url = directory.appending(path: "\(memoID.uuidString)-\(index).m4a")
        try data.write(to: url, options: .atomic)
        let segment = ClosedSegment(
          memoID: memoID, index: index, fileURL: url, byteCount: data.count, duration: policy.duration(frames: frames))
        eventContinuation.yield(.segmentClosed(segment, reason: reason))
      } catch {
        Log.capture.error("fake segment write failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "fake segment write failed"))
      }
    }
  }

  static func placeholderData(memoID: MemoID, index: Int, duration: TimeInterval) -> Data {
    // 8 + 7 + 1 = `headerLength` bytes.
    var data = Data("IRISFAKE".utf8) + Data(memoID.uuidString.utf8.prefix(7)) + Data([UInt8(truncatingIfNeeded: index)])
    let bodyLength = Int((duration * Double(bytesPerSecond)).rounded())
    data.append(contentsOf: (0..<bodyLength).map { UInt8(truncatingIfNeeded: ($0 &+ index) % 251) })
    return data
  }
}

/// The scripted bundle: session, routes, recorder and a steppable clock behind one handle.
public actor FakeCapture {
  /// Launch argument that swaps the real capture stack for this one.
  public static let launchArgument = "-IrisFakeCapture"
  /// Frames per fake tap buffer.
  static let bufferFrames = 4096

  public nonisolated let session: FakeAudioSessionController
  public nonisolated let routes: FakeRouteManager
  public nonisolated let recorder: FakeSegmentRecorder
  public nonisolated let clock: ManualClock
  private let policy: SegmentRotationPolicy
  private(set) var isInterrupted = false

  public init(
    directory: URL,
    clock: ManualClock = ManualClock(),
    policy: SegmentRotationPolicy = SegmentRotationPolicy(),
    routes: FakeRouteManager = FakeRouteManager()
  ) {
    self.clock = clock
    self.policy = policy
    self.routes = routes
    session = FakeAudioSessionController()
    recorder = FakeSegmentRecorder(directory: directory, policy: policy)
  }

  public static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
    arguments.contains(launchArgument)
  }

  @discardableResult
  public func startTake(memoID: MemoID = MemoID()) async throws -> MemoID {
    await session.configure()
    try await session.activate()
    try await recorder.start(memoID: memoID)
    return memoID
  }

  /// Records `seconds` of audio: feeds frames in tap-sized buffers and steps the clock by the same time.
  public func record(seconds: Double) async {
    var remaining = Int((seconds * Double(policy.sampleRate)).rounded())
    while remaining > 0 {
      let frames = min(remaining, Self.bufferFrames)
      await recorder.feed(frames: frames)
      remaining -= frames
    }
    await clock.advance(by: seconds)
  }

  /// The user (or a rule) switches the microphone mid-take: rolls the segment over.
  public func switchInput(to uid: String) async throws {
    try await routes.setPreferredInput(uid: uid)
    await recorder.rotate(for: .micSwitch)
  }

  public func interrupt() async {
    guard !isInterrupted else { return }
    isInterrupted = true
    await session.deliver(.began)
    await recorder.pause()
  }

  public func endInterruption(shouldResume: Bool = true) async {
    guard isInterrupted else { return }
    isInterrupted = false
    await session.deliver(.ended(shouldResume: shouldResume))
    if shouldResume { await recorder.resume() }
  }

  public func mediaServicesReset() async {
    await session.deliver(.mediaServicesReset)
  }

  public func engineConfigurationChanged() async {
    await recorder.rotate(for: .configurationChange)
  }

  public func stopTake() async throws {
    try await recorder.stop()
    await session.deactivate()
  }
}
