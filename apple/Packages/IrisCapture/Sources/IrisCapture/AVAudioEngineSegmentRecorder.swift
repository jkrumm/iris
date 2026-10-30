#if canImport(AVFAudio)
  import AVFAudio
  import Foundation

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
    private var isPaused = false

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

    public func start(memoID: MemoID) throws {
      try take.begin(memoID)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (stream, sink) = AsyncStream.makeStream(of: [Float].self)
        sampleSink = sink
        try installTapAndStartEngine(sink: sink)
        rotator = SegmentRotator(policy: policy)
        isPaused = false
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
      guard take.isRecording, !isPaused else { return }
      apply(rotator.rotate(for: .interruption), samples: [])
      isPaused = true
      engine.pause()
    }

    public func resume() {
      guard take.isRecording, isPaused, let sink = sampleSink else { return }
      do {
        let target = targetFormat
        let resumed = try EngineStartup.resume(
          InputTapEngine(engine: engine, target: target, sink: sink),
          replacement: { InputTapEngine(engine: AVAudioEngine(), target: target, sink: sink) })
        engine = resumed.engine
        isPaused = false
      } catch {
        Log.capture.error("engine resume failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "engine resume failed"))
      }
    }

    // MARK: Engine

    private func installTapAndStartEngine(sink: AsyncStream<[Float]>.Continuation) throws {
      try EngineStartup.bringUp(InputTapEngine(engine: engine, target: targetFormat, sink: sink))
    }

    /// Production `TapEngine`: the input tap converts to the target format and feeds `sink`.
    private struct InputTapEngine: TapEngine {
      let engine: AVAudioEngine
      let target: AVAudioFormat
      let sink: AsyncStream<[Float]>.Continuation

      func removeTap() { engine.inputNode.removeTap(onBus: 0) }

      func installTap() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
          throw CaptureError.engineFailure("no converter from the input format")
        }
        AVAudioEngineSegmentRecorder.installTap(
          on: input, format: inputFormat, converter: converter, target: target, sink: sink)
      }

      func start() throws {
        engine.prepare()
        try engine.start()
      }

      func stop() { engine.stop() }
    }

    /// Nonisolated on purpose: the tap block runs on the audio thread and must not inherit the actor.
    private nonisolated static func installTap(
      on input: AVAudioInputNode,
      format: AVAudioFormat,
      converter: AVAudioConverter,
      target: AVAudioFormat,
      sink: AsyncStream<[Float]>.Continuation
    ) {
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let samples = convert(buffer, with: converter, to: target) else { return }
        sink.yield(samples)
      }
    }

    private nonisolated static func convert(
      _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float]? {
      let ratio = format.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
      guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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

    /// An engine configuration change (route or format) stops the engine: roll the segment over, re-tap, restart.
    private func observeConfigurationChanges() {
      // Owned by the recorder; cancelled in `stop()`.
      configurationTask = Task {
        for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
          self.handleConfigurationChange()
        }
      }
    }

    private func handleConfigurationChange() {
      guard take.isRecording, !isPaused, let sink = sampleSink else { return }
      apply(rotator.rotate(for: .configurationChange), samples: [])
      do {
        try installTapAndStartEngine(sink: sink)
      } catch {
        Log.capture.error("engine restart failed: \(String(describing: error), privacy: .public)")
        eventContinuation.yield(.failed(reason: "engine restart failed"))
      }
    }

    // MARK: Segments

    private func ingest(_ samples: [Float]) {
      guard memoID != nil, !isPaused, !samples.isEmpty else { return }
      levelContinuation.yield(Self.rms(samples))
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

    private nonisolated static func rms(_ samples: [Float]) -> Float {
      let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
      return min(1, (sum / Float(samples.count)).squareRoot())
    }
  }
#endif
