#if canImport(AVFAudio)
  import AVFAudio
  import Foundation
  import IrisObjCGuard

  /// Production recorder: `AVAudioEngine` input tap -> `AVAudioConverter` (16 kHz mono) -> one
  /// `AVAudioFile` (AAC, ~32 kbps) per segment. Never `AVAudioRecorder` (D5): continuous buffers keep the
  /// concatenated decode gapless. Rotation decisions come from `SegmentRotator`.
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
    private var openFile: AVAudioFile?
    private var openFileURL: URL?
    private var sampleSink: AsyncStream<[Float]>.Continuation?
    private var consumeTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var run = EngineRun()
    private let deviceEvents: any CaptureEvents
    /// Counts the engines of this recorder; `capture.tap.install` and `audio.config_change` carry it.
    private var generation = 0
    private var levelReporter: LevelReporter
    /// When a configuration change closed the segment: the first sample of the fresh engine ends the gap.
    private var configurationGapStart: ContinuousClock.Instant?

    private var memoID: MemoID? { take.activeMemoID }

    public init(
      directory: URL, policy: SegmentRotationPolicy = SegmentRotationPolicy(),
      events deviceEvents: any CaptureEvents = NoCaptureEvents()
    ) throws {
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: Double(policy.sampleRate), channels: 1, interleaved: false)
      else { throw CaptureError.engineFailure("cannot build the 16 kHz mono format") }
      self.directory = directory
      self.policy = policy
      self.deviceEvents = deviceEvents
      levelReporter = LevelReporter(sampleRate: policy.sampleRate)
      targetFormat = format
      rotator = SegmentRotator(policy: policy)
      (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self)
      (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(memoID: MemoID) async throws {
      try take.begin(memoID)
      run.begin()
      configurationGapStart = nil
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
      configurationGapStart = nil
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

    /// Closes the open segment and drops the samples until `resume()`. The engine keeps running on purpose: a paused engine
    /// stops the hardware, the app loses the right to record, and the island's Resume (a `LiveActivityIntent` that runs with the
    /// app in the background) then cannot start it again ("engine resume failed", `!rec`). The microphone indicator stays on
    /// while paused; nothing is written.
    public func pause() {
      guard take.isRecording, !run.isPaused else { return }
      apply(rotator.rotate(for: .interruption), samples: [])
      _ = run.pause()
    }

    public func resume() async {
      guard take.isRecording, run.isPaused, let sink = sampleSink else { return }
      // A restart in flight brings the engine up running; the old one is torn down and must stay so.
      guard run.resume() == .startEngine else { return }
      let target = targetFormat
      let events = deviceEvents
      let current = generation
      do {
        let resumed = try await EngineStartup.resume(
          InputTapEngine(engine: engine, target: target, sink: sink, events: events, generation: current),
          replacement: {
            InputTapEngine(
              engine: AVAudioEngine(), target: target, sink: sink, events: events, generation: current + 1)
          },
          attempts: Self.restartAttempts,
          pause: { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.restartDelayMilliseconds))
            guard let self else { return false }
            return await self.isStillPaused
          })
        // The take ended or was paused again while the input was not ready: nothing to adopt, the replacement is torn down.
        guard let resumed else { return }
        guard take.isRecording, run.isPaused else {
          if resumed.engine !== engine {
            resumed.removeTap()
            resumed.stop()
          }
          return
        }
        engine = resumed.engine
        generation = resumed.generation
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
      let events = deviceEvents
      let current = generation
      let token = run.beginRestart()
      let fresh: InputTapEngine?
      do {
        fresh = try await EngineStartup.recover(
          InputTapEngine(engine: engine, target: target, sink: sink, events: events, generation: current),
          replacement: {
            InputTapEngine(
              engine: AVAudioEngine(), target: target, sink: sink, events: events, generation: current + 1)
          },
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
      generation = fresh.generation
    }

    /// Production `TapEngine`: the input tap converts to the target format and feeds `sink`.
    private struct InputTapEngine: TapEngine {
      let engine: AVAudioEngine
      let target: AVAudioFormat
      let sink: AsyncStream<[Float]>.Continuation
      let events: any CaptureEvents
      let generation: Int

      var isRunning: Bool { engine.isRunning }

      func removeTap() { Self.guarded("removing the tap") { engine.inputNode.removeTap(onBus: 0) } }

      func installTap() throws {
        let input = engine.inputNode
        // The tap's format is the node's current one, and it must agree with the hardware: a mismatch (the route is mid-switch,
        // AirPods report no format while the Bluetooth link comes up) raises an Objective-C exception that aborts the process.
        // Refuse it here so the caller retries, and keep the shim as the net under the checks.
        let format = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        let valid = format.sampleRate > 0 && format.channelCount > 0 && format.sampleRate == hardware.sampleRate
        // Written before the call that can abort the process: the last one before a gap in `seq` is the one that did.
        events.preflight(
          "capture.tap.install",
          [
            "rate": .double(format.sampleRate), "channels": .int(Int(format.channelCount)),
            "hardware_rate": .double(hardware.sampleRate), "valid": .bool(valid), "generation": .int(generation),
          ])
        guard valid else {
          throw CaptureError.engineFailure("the input format is not ready")
        }
        let converter = TapConverter(target: target)
        let sink = sink
        do {
          try IrisObjCGuard.perform {
            AVAudioEngineSegmentRecorder.installTap(on: input, format: format, converter: converter, sink: sink)
          }
        } catch {
          events.sessionError(call: "installTap", error: error, engineRunning: engine.isRunning)
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
          events.sessionError(call: "engine.start", error: error, engineRunning: engine.isRunning)
          throw CaptureError.engineFailure("starting the engine failed: \(error.localizedDescription)")
        }
        if let startError {
          events.sessionError(call: "engine.start", error: startError, engineRunning: engine.isRunning)
          throw startError
        }
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
      reportConfigurationChange()
      apply(rotator.rotate(for: .configurationChange), samples: [])
      configurationGapStart = .now
      let target = targetFormat
      let events = deviceEvents
      let current = generation
      let token = run.beginRestart()
      let fresh: InputTapEngine?
      do {
        fresh = try await EngineStartup.recover(
          InputTapEngine(engine: engine, target: target, sink: sink, events: events, generation: current),
          replacement: {
            InputTapEngine(
              engine: AVAudioEngine(), target: target, sink: sink, events: events, generation: current + 1)
          },
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
      generation = fresh.generation
    }

    private static let restartAttempts = 6
    private static let startAttempts = 4
    private static let restartDelayMilliseconds = 250
    private var isStillRecording: Bool { take.isRecording }
    private var isStillPaused: Bool { take.isRecording && run.isPaused }

    // MARK: Segments

    private func ingest(_ samples: [Float]) {
      guard memoID != nil, !run.isPaused, !samples.isEmpty else { return }
      levelContinuation.yield(InputLevel.meter(samples))
      reportLevel(samples)
      apply(rotator.append(frames: samples.count), samples: samples)
    }

    /// `capture.level` twice a second, and the end of a configuration-change gap at the first sample after it.
    private func reportLevel(_ samples: [Float]) {
      if let start = configurationGapStart {
        configurationGapStart = nil
        let elapsed = ContinuousClock.now - start
        let milliseconds =
          Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        deviceEvents.event(
          "capture.gap",
          memoID: memoID,
          [
            "ms": .int(milliseconds), "reason": "config_change",
            "frames_lost": .int(milliseconds * policy.sampleRate / 1000),
          ])
      }
      guard let level = levelReporter.add(samples) else { return }
      deviceEvents.event(
        "capture.level", memoID: memoID,
        ["rms_db": .double(level.rmsDecibels), "peak_db": .double(level.peakDecibels)])
    }

    /// `audio.config_change`: what the engine's input looked like when the system said it changed.
    private func reportConfigurationChange() {
      let format = engine.inputNode.inputFormat(forBus: 0)
      deviceEvents.event(
        "audio.config_change", memoID: memoID,
        SessionSnapshot.attributes().merging([
          "engine.running_before": .bool(engine.isRunning), "input.rate_before": .double(format.sampleRate),
          "input.channels_before": .int(Int(format.channelCount)), "generation": .int(generation),
        ]) { current, _ in current })
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
        let file = try openFile ?? makeFile(segment: segment, memoID: memoID)
        guard
          let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = buffer.floatChannelData
        else { return }
        samples.withUnsafeBufferPointer { source in
          guard let base = source.baseAddress else { return }
          channel[0].update(from: base, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
      } catch {
        Log.capture.error("segment write failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "segment write failed"))
      }
    }

    private func makeFile(segment: Int, memoID: MemoID) throws -> AVAudioFile {
      let url = directory.appending(path: "\(memoID.uuidString)-\(segment).m4a")
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Double(policy.sampleRate),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
      ]
      let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      openFile = file
      openFileURL = url
      return file
    }

    private func close(segment: Int, frames: Int, reason: RotationReason, memoID: MemoID) {
      // Releasing the AVAudioFile finalizes the m4a.
      let url = openFileURL
      openFile = nil
      openFileURL = nil
      guard let url else { return }
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
      let closed = ClosedSegment(
        memoID: memoID, index: segment, fileURL: url, byteCount: size, duration: policy.duration(frames: frames))
      eventContinuation.yield(.segmentClosed(closed, reason: reason))
    }
  }
#endif
