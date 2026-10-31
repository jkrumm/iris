#if canImport(AVFAudio)
  import AVFAudio
  import Foundation
  import IrisObjCGuard

  /// Production recorder: `AVAudioEngine` input tap -> `AVAudioConverter` (16 kHz mono) -> one
  /// `AVAudioFile` (AAC, ~32 kbps) per segment. Never `AVAudioRecorder` (D5): continuous buffers keep the
  /// concatenated decode gapless. Rotation decisions come from `SegmentRotator`.
  ///
  /// Each open segment also has a crash-safe PCM copy (`SegmentWriter`) that the next launch's sweep recovers after a kill.
  ///
  /// Thin on purpose; device-verified in spike S1/S2, only compile-checked in the package tests.
  public actor AVAudioEngineSegmentRecorder: SegmentRecorder {
    public nonisolated let events: AsyncStream<CaptureEvent>
    public nonisolated let levels: AsyncStream<Float>

    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    private let levelContinuation: AsyncStream<Float>.Continuation
    private let directory: URL
    private let policy: SegmentRotationPolicy
    private var engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat

    private var rotator: SegmentRotator
    private var take = TakeLifecycle()
    private var openSegment: SegmentWriter?
    private var sampleSink: AsyncStream<[Float]>.Continuation?
    private var consumeTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var run = EngineRun()

    private var memoID: MemoID? { take.activeMemoID }

    public init(directory: URL, policy: SegmentRotationPolicy = SegmentRotationPolicy()) throws {
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: Double(policy.sampleRate), channels: 1, interleaved: false)
      else { throw CaptureError.engineFailure("cannot build the 16 kHz mono format") }
      self.directory = directory
      self.policy = policy
      targetFormat = format
      rotator = SegmentRotator(policy: policy)
      (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self)
      (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(memoID: MemoID) async throws {
      try take.begin(memoID)
      run.begin()
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (stream, sink) = AsyncStream.makeStream(of: [Float].self)
        sampleSink = sink
        try await bringUpFirstEngine(sink: sink)
        rotator = SegmentRotator(policy: policy)
        // Owned by the recorder; ends when `stop()` finishes the stream.
        consumeTask = Task {
          for await samples in stream { self.ingest(samples) }
        }
        observeConfigurationChanges()
        eventContinuation.yield(.started(memoID))
      } catch {
        sampleSink?.finish()
        sampleSink = nil
        take.abortStart()
        throw CaptureError.engineFailure(String(describing: error))
      }
    }

    public func stop() async throws {
      // Claimed synchronously: the awaits below let other calls in, and they must see a stopping take.
      let memoID = try take.beginStop()
      run.end()
      configurationTask?.cancel()
      configurationTask = nil
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      sampleSink?.finish()
      sampleSink = nil
      await consumeTask?.value
      consumeTask = nil
      apply(rotator.finish(), samples: [])
      eventContinuation.yield(.stopped(memoID, segmentCount: rotator.closedCount))
      take.finishStop()
    }

    public func rotate(for reason: RotationReason) {
      guard take.isRecording else { return }
      apply(rotator.rotate(for: reason), samples: [])
    }

    public func pause() {
      guard take.isRecording, !run.isPaused else { return }
      apply(rotator.rotate(for: .interruption), samples: [])
      if run.pause() == .pauseEngine { engine.pause() }
    }

    public func resume() {
      guard take.isRecording, run.isPaused, let sink = sampleSink else { return }
      // A restart in flight brings the engine up running; the old one is torn down and must stay so.
      guard run.resume() == .startEngine else { return }
      do {
        let target = targetFormat
        let resumed = try EngineStartup.resume(
          InputTapEngine(engine: engine, target: target, sink: sink),
          replacement: { InputTapEngine(engine: AVAudioEngine(), target: target, sink: sink) })
        engine = resumed.engine
        run.resumed()
      } catch {
        Log.capture.error("engine resume failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "engine resume failed"))
      }
    }

    // MARK: Engine

    /// The first engine of a take. With AirPods already connected the input can report no format for a moment after the session
    /// activates (an `installTap` then aborts the process), so it is retried like a restart before the start fails.
    private func bringUpFirstEngine(sink: AsyncStream<[Float]>.Continuation) async throws {
      let target = targetFormat
      let token = run.beginRestart()
      let fresh: InputTapEngine?
      do {
        fresh = try await EngineStartup.recover(
          InputTapEngine(engine: engine, target: target, sink: sink),
          replacement: { InputTapEngine(engine: AVAudioEngine(), target: target, sink: sink) },
          attempts: Self.startAttempts,
          pause: {
            try? await Task.sleep(for: .milliseconds(Self.restartDelayMilliseconds))
            return true
          })
      } catch {
        _ = run.endRestart(token)
        throw error
      }
      let verdict = run.endRestart(token)
      guard let fresh else { throw CaptureError.engineFailure("the engine did not start") }
      guard verdict != .discard, take.isRecording else {
        fresh.removeTap()
        fresh.stop()
        throw CaptureError.engineFailure("the take ended while the engine started")
      }
      engine = fresh.engine
      if verdict == .keepPaused { engine.pause() }  // paused while the first engine was coming up
    }

    /// Production `TapEngine`: the input tap converts to the target format and feeds `sink`.
    private struct InputTapEngine: TapEngine {
      let engine: AVAudioEngine
      let target: AVAudioFormat
      let sink: AsyncStream<[Float]>.Continuation

      func removeTap() { Self.guarded("removing the tap") { engine.inputNode.removeTap(onBus: 0) } }

      func installTap() throws {
        let input = engine.inputNode
        // The tap's format is the node's current one, and it must agree with the hardware: a mismatch (the route is mid-switch,
        // AirPods report no format while the Bluetooth link comes up) raises an Objective-C exception that aborts the process.
        // Refuse it here so the caller retries, and keep the shim as the net under the checks.
        let format = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.sampleRate == hardware.sampleRate else {
          throw CaptureError.engineFailure("the input format is not ready")
        }
        let converter = TapConverter(target: target)
        let sink = sink
        do {
          try IrisObjCGuard.perform {
            AVAudioEngineSegmentRecorder.installTap(on: input, format: format, converter: converter, sink: sink)
          }
        } catch {
          throw CaptureError.engineFailure("installing the tap failed: \(error.localizedDescription)")
        }
      }

      func start() throws {
        var startError: (any Error)?
        do {
          try IrisObjCGuard.perform {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
          }
        } catch {
          throw CaptureError.engineFailure("starting the engine failed: \(error.localizedDescription)")
        }
        if let startError { throw startError }
      }

      func stop() { Self.guarded("stopping the engine") { engine.stop() } }

      /// Teardown must not abort the process, and must not vanish either: an exception is logged.
      private static func guarded(_ what: String, _ work: () -> Void) {
        do {
          try IrisObjCGuard.perform(work)
        } catch {
          Log.capture.error("\(what, privacy: .public) raised: \(error.localizedDescription, privacy: .public)")
        }
      }
    }

    /// Nonisolated on purpose: the tap block runs on the audio thread and must not inherit the actor.
    private nonisolated static func installTap(
      on input: AVAudioInputNode, format: AVAudioFormat, converter: TapConverter,
      sink: AsyncStream<[Float]>.Continuation
    ) {
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let samples = converter.convert(buffer) else { return }
        sink.yield(samples)
      }
    }

    /// Converts tap buffers to the 16 kHz mono target. The converter follows the buffers' format, so an input that changes
    /// under a running tap (AirPods connecting) is converted from its new format instead of mis-read from the old one.
    private final class TapConverter: @unchecked Sendable {
      // Touched only from the tap block, which AVAudioEngine calls one buffer at a time on a single thread per tap.
      private let target: AVAudioFormat
      private var converter: AVAudioConverter?
      private var source: AVAudioFormat?

      init(target: AVAudioFormat) { self.target = target }

      func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.format.sampleRate > 0, buffer.frameLength > 0 else { return nil }
        if source != buffer.format {
          guard let fresh = AVAudioConverter(from: buffer.format, to: target) else { return nil }
          converter = fresh
          source = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false  // read and written only by this call's synchronous convert
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
          if supplied {
            inputStatus.pointee = .noDataNow
            return nil
          }
          supplied = true
          inputStatus.pointee = .haveData
          return buffer
        }
        guard status != .error, error == nil, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
      }
    }

    /// An engine configuration change (route or format) stops the engine: roll the segment over and bring up a fresh engine on
    /// the new input. The old engine's input node can still describe the old hardware, and a tap installed against that aborts
    /// the process; a fresh engine reads the hardware as it is now. The input is often not ready for a moment after a switch
    /// (AirPods report no format while the Bluetooth link comes up), so the bring-up is retried before the take fails.
    private func observeConfigurationChanges() {
      // Owned by the recorder; cancelled in `stop()`.
      configurationTask = Task {
        for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
          await self.handleConfigurationChange()
        }
      }
    }

    private func handleConfigurationChange() async {
      guard take.isRecording, !run.isPaused, let sink = sampleSink else { return }
      apply(rotator.rotate(for: .configurationChange), samples: [])
      let target = targetFormat
      let token = run.beginRestart()
      let fresh: InputTapEngine?
      do {
        fresh = try await EngineStartup.recover(
          InputTapEngine(engine: engine, target: target, sink: sink),
          replacement: { InputTapEngine(engine: AVAudioEngine(), target: target, sink: sink) },
          attempts: Self.restartAttempts,
          pause: { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.restartDelayMilliseconds))
            guard let self else { return false }
            return await self.isStillRecording
          })
      } catch {
        // A stale restart (the take ended, another began) has nothing to report.
        guard run.endRestart(token) != .discard, take.isRecording else { return }
        Log.capture.error("engine restart failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "engine restart failed"))
        return
      }
      let verdict = run.endRestart(token)
      guard let fresh else { return }  // the take ended while the input was not ready: nothing is running
      // The take ended while the fresh engine came up (the check inside `recover` and this line are two actor turns apart).
      guard verdict != .discard, take.isRecording else {
        fresh.removeTap()
        fresh.stop()
        return
      }
      engine.stop()
      engine = fresh.engine
      if verdict == .keepPaused { engine.pause() }  // paused while the engine was coming up
    }

    private static let restartAttempts = 6
    private static let startAttempts = 4
    private static let restartDelayMilliseconds = 250
    private var isStillRecording: Bool { take.isRecording }

    // MARK: Segments

    private func ingest(_ samples: [Float]) {
      guard memoID != nil, !run.isPaused, !samples.isEmpty else { return }
      levelContinuation.yield(InputLevel.meter(samples))
      apply(rotator.append(frames: samples.count), samples: samples)
    }

    private func apply(_ actions: [SegmentAction], samples: [Float]) {
      guard let memoID else { return }
      var offset = 0
      for action in actions {
        switch action {
        case .write(let segment, let frames):
          write(Array(samples[offset..<offset + frames]), segment: segment, memoID: memoID)
          offset += frames
        case .close(let segment, let frames, let reason):
          close(segment: segment, frames: frames, reason: reason, memoID: memoID)
        }
      }
    }

    private func write(_ samples: [Float], segment: Int, memoID: MemoID) {
      do {
        let writer = try openSegment ?? makeWriter(segment: segment, memoID: memoID)
        guard
          let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = buffer.floatChannelData
        else { return }
        samples.withUnsafeBufferPointer { source in
          guard let base = source.baseAddress else { return }
          channel[0].update(from: base, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try writer.write(buffer)
      } catch {
        Log.capture.error("segment write failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "segment write failed"))
      }
    }

    private func makeWriter(segment: Int, memoID: MemoID) throws -> SegmentWriter {
      let url = directory.appending(path: "\(memoID.uuidString)-\(segment).m4a")
      let writer = try SegmentWriter(url: url, sampleRate: policy.sampleRate)
      openSegment = writer
      return writer
    }

    private func close(segment: Int, frames: Int, reason: RotationReason, memoID: MemoID) {
      // Releasing the AVAudioFile finalizes the m4a; the PCM shadow beside it goes once the m4a reads back at its length.
      guard let writer = openSegment else { return }
      openSegment = nil
      let url = writer.url
      guard writer.close() != .unreadable else {
        // Neither readable nor rebuilt: queueing it would upload a file the server cannot use. Both files stay for the sweep.
        Log.capture.error("segment \(url.lastPathComponent, privacy: .public) is unreadable and was not queued")
        eventContinuation.yield(.failed(reason: "segment unreadable"))
        return
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
      let closed = ClosedSegment(
        memoID: memoID, index: segment, fileURL: url, byteCount: size, duration: policy.duration(frames: frames))
      eventContinuation.yield(.segmentClosed(closed, reason: reason))
    }
  }

  /// The take screen's meter value: the buffer's RMS on a perceptual (dB) scale, not the linear amplitude, which
  /// leaves normal speech (about -30 dBFS, 0.03 linear) at a barely visible 3 %. Silence at or below ``floorDecibels``
  /// reads 0, ``ceilingDecibels`` and above read 1, and a clipped sample (|x| at full scale) reads 1 whatever the RMS.
  enum InputLevel {
    /// Quieter than this is the room, not the voice.
    static let floorDecibels: Float = -50
    /// Speech this loud already fills the meter.
    static let ceilingDecibels: Float = -10
    static let clippingPeak: Float = 0.99

    static func meter(_ samples: [Float]) -> Float {
      guard !samples.isEmpty else { return 0 }
      let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
      if peak >= clippingPeak { return 1 }
      let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
      return meter(rms: meanSquare.squareRoot())
    }

    /// 0...1: linear in decibels between the floor and the ceiling.
    static func meter(rms: Float) -> Float {
      guard rms > 0 else { return 0 }
      let decibels = 20 * log10(rms)
      return min(max((decibels - floorDecibels) / (ceilingDecibels - floorDecibels), 0), 1)
    }
  }
#endif
