#if canImport(AVFAudio)
  import AVFoundation
  import CoreMedia
  import Foundation

  /// One segment file: 16 kHz mono AAC in a **fragmented** `.m4a`.
  ///
  /// A fragmented MP4 repeats its sample tables in every fragment (`movieFragmentInterval`), so a file whose writer was killed
  /// (force-quit, jetsam, a crash) is still a playable file up to the last whole fragment. A plain `AVAudioFile` m4a keeps its
  /// index (`moov`) for the close and is unreadable when it never comes (`docs/research/2026-10-30-avaudiofile-kill.md`). The
  /// name and the container are unchanged (`audio/mp4`), so the uploader, the server's concat and the startup sweep treat a
  /// killed tail like any other segment file.
  ///
  /// `@unchecked Sendable`: owned by the recorder actor, which calls `append` and then hands the writer to exactly one
  /// closing task; after that hand-off only `finish()` touches it, so the two never overlap.
  final class SegmentWriter: @unchecked Sendable {
    /// What a finished segment file is: its size and the frames it reads back with. `error` is what the writer reported, if
    /// anything; a file that reads back is queued whatever the writer said, nothing is thrown away.
    struct Outcome: Sendable, Equatable {
      let byteCount: Int
      let readableFrames: Int
      let error: String?
    }

    struct WriterError: Error, CustomStringConvertible {
      let description: String
    }

    /// A kill loses at most this much plus the encoder's latency (measured: 0.2–0.5 s).
    static let fragmentInterval = 0.5
    /// `finish()` gives the input this long to take the audio it still holds before the file is closed with what it has.
    private static let drainLimit: Duration = .seconds(5)

    let url: URL
    private let sampleRate: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private var framesAppended = 0
    /// Buffers the real-time input was not ready for yet; written in order before anything newer.
    private var backlog: [CMSampleBuffer] = []

    init(url: URL, sampleRate: Int) throws {
      self.url = url
      self.sampleRate = sampleRate
      writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
      writer.movieFragmentInterval = CMTime(seconds: Self.fragmentInterval, preferredTimescale: 600)
      input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(sampleRate), AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 32_000,
        ])
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw WriterError(description: "the writer takes no audio input") }
      writer.add(input)

      var description = AudioStreamBasicDescription(
        mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
      var created: CMAudioFormatDescription?
      let status = CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &created)
      guard status == noErr, let created else {
        throw WriterError(description: "no audio format description (\(status))")
      }
      format = created
      guard writer.startWriting() else { throw WriterError(description: Self.reason(writer.error, "startWriting")) }
      writer.startSession(atSourceTime: .zero)
    }

    /// Appends the samples; they continue where the last call ended, so the segment is gapless.
    func append(_ samples: [Float]) throws {
      guard !samples.isEmpty else { return }
      guard writer.status == .writing else { throw WriterError(description: Self.reason(writer.error, "append")) }
      backlog.append(try makeBuffer(samples))
      framesAppended += samples.count
      try drain()
    }

    /// Closes the file and reads it back. Waits (off the caller's executor) for the input to take what it still holds.
    func finish() async -> Outcome {
      var failure: String?
      do {
        let deadline = ContinuousClock.now + Self.drainLimit
        try drain()
        while !backlog.isEmpty {
          guard ContinuousClock.now < deadline else { throw WriterError(description: "the encoder did not drain") }
          try await Task.sleep(for: .milliseconds(10))
          try drain()
        }
      } catch {
        failure = String(describing: error)
      }
      if writer.status == .writing {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(framesAppended), timescale: CMTimeScale(sampleRate)))
        await writer.finishWriting()
      }
      if writer.status != .completed, failure == nil { failure = Self.reason(writer.error, "finishWriting") }
      return Outcome(byteCount: Self.byteCount(of: url), readableFrames: Self.readableFrames(of: url), error: failure)
    }

    // MARK: Internals

    private func drain() throws {
      while let next = backlog.first, input.isReadyForMoreMediaData {
        guard input.append(next) else { throw WriterError(description: Self.reason(writer.error, "append")) }
        backlog.removeFirst()
      }
    }

    private func makeBuffer(_ samples: [Float]) throws -> CMSampleBuffer {
      let byteCount = samples.count * MemoryLayout<Float>.size
      var block: CMBlockBuffer?
      var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
      guard status == noErr, let block else { throw WriterError(description: "no block buffer (\(status))") }
      status = samples.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
        return CMBlockBufferReplaceDataBytes(
          with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
      }
      guard status == noErr else { throw WriterError(description: "block buffer not filled (\(status))") }
      var buffer: CMSampleBuffer?
      status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
        presentationTimeStamp: CMTime(value: CMTimeValue(framesAppended), timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &buffer)
      guard status == noErr, let buffer else { throw WriterError(description: "no sample buffer (\(status))") }
      return buffer
    }

    private static func reason(_ error: (any Error)?, _ call: String) -> String {
      "\(call): \(error.map { String(describing: $0) } ?? "no error reported")"
    }

    private static func byteCount(of url: URL) -> Int {
      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func readableFrames(of url: URL) -> Int {
      guard let file = try? AVAudioFile(forReading: url) else { return 0 }
      return Int(file.length)
    }
  }
#endif
