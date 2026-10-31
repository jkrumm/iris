#if canImport(AVFAudio)
  import AVFAudio
  import Foundation
  import Testing

  @testable import IrisCapture

  /// A force-quit must not lose the segment being recorded (Wave 18 I2, `docs/research/2026-10-30-avaudiofile-kill.md`).
  /// Real AVFoundation on the macOS host, no fakes. A process kill drops no byte the writer already handed to the OS, so a
  /// copy of the file taken while the writer is still open is the state a SIGKILL leaves (the research note's experiment
  /// killed a real child process and measured the same).
  struct KilledSegmentTests {
    private let rate = 16_000

    private func noise(seconds: Double) -> [Float] {
      (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -0.3...0.3) }
    }

    private func frames(of url: URL) -> Int {
      guard let file = try? AVAudioFile(forReading: url) else { return 0 }
      return Int(file.length)
    }

    /// Writes `seconds` in 0.25 s tap-sized chunks and returns the still-open writer.
    private func openWriter(_ id: MemoID, _ index: Int, seconds: Double, in directory: URL) throws -> SegmentWriter {
      let writer = try SegmentWriter(url: directory.appending(path: "\(id.uuidString)-\(index).m4a"), sampleRate: rate)
      for _ in 0..<Int(seconds * 4) { try writer.append(noise(seconds: 0.25)) }
      return writer
    }

    /// What a kill leaves of `writer`: a copy taken once the encoder has flushed at least `seconds` of it.
    private func killed(_ writer: SegmentWriter, into directory: URL, atLeast seconds: Double) async throws -> URL {
      let copy = directory.appending(path: writer.url.lastPathComponent)
      let deadline = ContinuousClock.now + .seconds(10)
      while ContinuousClock.now < deadline {
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: writer.url, to: copy)
        if Double(frames(of: copy)) / Double(rate) >= seconds { return copy }
        try await Task.sleep(for: .milliseconds(50))
      }
      return copy
    }

    @Test func aKilledSegmentStillPlaysAndKeepsAllButTheLastFragment() async throws {
      let live = try temporaryDirectory()
      let dead = try temporaryDirectory()
      defer { for directory in [live, dead] { try? FileManager.default.removeItem(at: directory) } }
      let writer = try openWriter(memo(1), 0, seconds: 6, in: live)

      let copy = try await killed(writer, into: dead, atLeast: 4.5)

      let kept = Double(frames(of: copy)) / Double(rate)
      #expect(
        kept >= 4.5, "a killed 6 s segment keeps all but the open fragment and the encoder's latency, kept \(kept) s")
      #expect(Outbox.inspectAudioFile(copy) != nil, "the sweep's own inspector accepts it")
      _ = await writer.finish()
    }

    /// The premise: what the recorder wrote before, an `AVAudioFile` m4a, is unreadable when it is killed open.
    @Test func theOldAVAudioFileWriterLeavesNothingReadableWhenKilled() throws {
      let live = try temporaryDirectory()
      let dead = try temporaryDirectory()
      defer { for directory in [live, dead] { try? FileManager.default.removeItem(at: directory) } }
      let url = live.appending(path: "old.m4a")
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(rate), AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
      ]
      let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false))
      for _ in 0..<24 {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = 4_096
        for frame in 0..<4_096 { buffer.floatChannelData?[0][frame] = Float.random(in: -0.3...0.3) }
        try file.write(from: buffer)
      }
      let copy = dead.appending(path: "old.m4a")
      try FileManager.default.copyItem(at: url, to: copy)

      #expect(frames(of: copy) == 0, "no moov atom, no index: the 6 s are gone")
      withExtendedLifetime(file) {}
    }

    @Test func aFileCutAnywhereAfterTheFirstFragmentKeepsAPlayablePrefix() async throws {
      let live = try temporaryDirectory()
      let dead = try temporaryDirectory()
      defer { for directory in [live, dead] { try? FileManager.default.removeItem(at: directory) } }
      let writer = try openWriter(memo(1), 0, seconds: 6, in: live)
      let copy = try await killed(writer, into: dead, atLeast: 4.5)
      _ = await writer.finish()
      let whole = try Data(contentsOf: copy)

      // A kill between the writes of one fragment cuts it short; every cut from a third of the file on keeps a prefix.
      var previous = 0
      for step in 4...20 {
        let cut = whole.count * step / 20
        let cutFile = dead.appending(path: "cut-\(step).m4a")
        try whole.prefix(cut).write(to: cutFile)
        let kept = frames(of: cutFile)
        #expect(kept > 0, "cut at \(cut) of \(whole.count) bytes")
        #expect(kept >= previous, "a longer cut never reads shorter")
        previous = kept
      }
    }

    @Test func aCleanFinishReadsBackWholeAndGaplessAcrossTheChunks() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let writer = try openWriter(memo(1), 0, seconds: 3, in: directory)

      let outcome = await writer.finish()

      #expect(outcome.error == nil)
      #expect(outcome.byteCount > 0)
      // AAC pads to whole 1024-frame packets; nothing is missing and nothing is a gap.
      #expect(abs(outcome.readableFrames - 3 * rate) <= 2_048, "read back \(outcome.readableFrames) of \(3 * rate)")
    }

    @Test func aWriterThatFailedKeepsWhatItWroteAndSaysSo() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let writer = try openWriter(memo(1), 0, seconds: 2, in: directory)
      _ = await writer.finish()

      #expect(throws: (any Error).self) { try writer.append(noise(seconds: 0.25)) }
      #expect(frames(of: writer.url) > 0, "a refused append leaves the finished file as it was")
    }

    // MARK: The sweep adopts the killed tail

    private func killedTakeOnDisk(_ id: MemoID, in directory: URL) async throws -> (OutboxRecord, tail: URL) {
      let live = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: live) }
      var item = voiceItem(id)
      item.create = .uploaded
      item.createMayHaveLanded = true
      var entries: [OutboxEntry] = []
      for index in 0..<2 {
        let writer = try openWriter(id, index, seconds: 2, in: directory)
        let outcome = await writer.finish()
        entries.append(
          OutboxEntry(
            segment: ClosedSegment(
              memoID: id, index: index, fileURL: writer.url, byteCount: outcome.byteCount, duration: 2),
            sequence: index,
            state: .uploaded, attempts: 0))
      }
      let open = try openWriter(id, 2, seconds: 6, in: live)
      let tail = try await killed(open, into: directory, atLeast: 4.5)
      _ = await open.finish()
      return (OutboxRecord(entries: entries, items: [item], nextSequence: 2), tail)
    }

    @Test func theSweepAdoptsAKilledTailAndQueuesItForUpload() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let id = memo(1)
      let (record, tail) = try await killedTakeOnDisk(id, in: directory)
      let harness = try await OutboxHarness(record: record, deletesFilesWhenDone: false)

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.adopted == [tail] && report.quarantined.isEmpty && report.stuck.isEmpty)
      await harness.outbox.settled()
      #expect(await harness.uploader.uploaded.map(\.index) == [2])
      #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 3)], "the tail is part of the memo")
      #expect(FileManager.default.fileExists(atPath: tail.path), "nothing is deleted")
      await harness.outbox.shutdown()
    }

    @Test func aKilledFileThatDoesNotPlayIsSetAsideNotDeleted() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let id = memo(1)
      let (record, tail) = try await killedTakeOnDisk(id, in: directory)
      // Killed before the first fragment: the header only.
      let stub = try Data(contentsOf: tail).prefix(40)
      try stub.write(to: tail)
      let harness = try await OutboxHarness(record: record, deletesFilesWhenDone: false)

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.adopted.isEmpty && report.quarantined.count == 1)
      let moved = try #require(report.quarantined.first)
      #expect(try Data(contentsOf: moved) == stub, "kept byte for byte")
      await harness.outbox.shutdown()
    }
  }
#endif
