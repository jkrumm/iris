#if canImport(AVFAudio)
  import AVFAudio
  import Foundation
  import Synchronization
  import Testing

  @testable import IrisCapture

  /// A force-quit loses the open segment's m4a (no index, `docs/research/2026-10-30-avaudiofile-kill.md`) but not the PCM shadow
  /// beside it. The files are copied while the writer is still open: the state a kill leaves on disk, since a process kill drops
  /// no written byte. Real AVFoundation on the macOS host, no fakes.
  struct ShadowRecoveryTests {
    private let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// `seconds` of speech-like noise through a real `SegmentWriter`.
    private func writeSegment(_ id: MemoID, _ index: Int, seconds: Double, in directory: URL) throws -> SegmentWriter {
      let writer = try SegmentWriter(
        url: directory.appending(path: "\(id.uuidString)-\(index).m4a"), sampleRate: 16_000)
      for _ in 0..<Int(seconds * 10) {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = Float.random(in: -0.3...0.3) }
        buffer.frameLength = 1_600
        try writer.write(buffer)
      }
      return writer
    }

    /// What a SIGKILL leaves of `writer`'s files: copies taken while it is still open.
    private func killed(_ writer: SegmentWriter, into directory: URL) throws {
      for source in [writer.url, SegmentShadow.url(of: writer.url)] {
        try FileManager.default.copyItem(at: source, to: directory.appending(path: source.lastPathComponent))
      }
    }

    private func names(_ directory: URL) -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func aKilledSegmentHasNoPlayableM4aButAWholeShadow() throws {
      let live = try temporaryDirectory()
      let dead = try temporaryDirectory()
      defer { for directory in [live, dead] { try? FileManager.default.removeItem(at: directory) } }
      let writer = try writeSegment(memo(1), 0, seconds: 4, in: live)
      try killed(writer, into: dead)
      writer.close()

      let m4a = dead.appending(path: "\(memo(1).uuidString)-0.m4a")
      #expect(Outbox.inspectAudioFile(m4a) == nil, "the premise: an AAC m4a killed before close does not play")
      let shadow = try AVAudioFile(forReading: SegmentShadow.url(of: m4a))
      #expect(Double(shadow.length) / 16_000 >= 3.9, "the shadow holds the audio")
    }

    @Test func aCleanCloseRemovesTheShadowAndLeavesAPlayableM4a() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let writer = try writeSegment(memo(1), 0, seconds: 2, in: directory)
      writer.close()

      #expect(names(directory) == ["\(memo(1).uuidString)-0.m4a"])
      let audio = try #require(Outbox.inspectAudioFile(writer.url))
      #expect(abs(audio.duration - 2) < 0.2)
    }

    /// A segment writer whose m4a reads back as unplayable for the first `failures` checks, then as it is.
    private func writer(_ id: MemoID, in directory: URL, failures: Int) throws -> SegmentWriter {
      let remaining = Mutex(failures)
      let url = directory.appending(path: "\(id.uuidString)-0.m4a")
      let writer = try SegmentWriter(
        url: url, sampleRate: 16_000,
        readsBack: { file in
          let fail = remaining.withLock { count in
            defer { count -= 1 }
            return count > 0
          }
          return fail ? nil : SegmentWriter.duration(of: file)
        })
      for _ in 0..<30 {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = Float.random(in: -0.3...0.3) }
        buffer.frameLength = 1_600
        try writer.write(buffer)
      }
      return writer
    }

    @Test func aClosedM4aThatDoesNotReadBackIsRebuiltFromItsShadowBeforeItIsHandedOut() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let writer = try writer(memo(1), in: directory, failures: 1)

      #expect(writer.close() == .recoveredFromShadow)

      let audio = try #require(Outbox.inspectAudioFile(writer.url))
      #expect(abs(audio.duration - 3) < 0.3)
      #expect(!names(directory).contains { $0.hasSuffix(".caf") }, "the shadow goes once the rebuilt m4a reads back")
    }

    @Test func aSegmentThatCannotBeRebuiltIsUnreadableAndKeepsBothFiles() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let writer = try writer(memo(1), in: directory, failures: 100)

      #expect(writer.close() == .unreadable, "the recorder must not queue it")
      #expect(names(directory).count == 2, "m4a and shadow stay for the next launch's sweep")
    }

    @Test func recoveringAShadowGivesAPlayableM4aOfTheSameLength() throws {
      let live = try temporaryDirectory()
      let dead = try temporaryDirectory()
      defer { for directory in [live, dead] { try? FileManager.default.removeItem(at: directory) } }
      let writer = try writeSegment(memo(1), 3, seconds: 6, in: live)
      try killed(writer, into: dead)
      writer.close()
      let shadow = dead.appending(path: "\(memo(1).uuidString)-3.caf")

      let result = SegmentWriter.recover(shadow: shadow, sampleRate: 16_000)

      guard case .recovered(let url) = result else {
        Issue.record("expected a recovered file, got \(result)")
        return
      }
      #expect(url.lastPathComponent == "\(memo(1).uuidString)-3.m4a", "it replaces the truncated m4a")
      let audio = try #require(Outbox.inspectAudioFile(url))
      #expect(abs(audio.duration - 6) < 0.5, "got \(audio.duration) s")
      #expect(FileManager.default.fileExists(atPath: shadow.path), "recover never touches the shadow")
    }

    /// A CAF header as AVAudioFile writes it before any audio: `caff`, version, flags, a `desc` chunk, optionally `data`.
    private func cafHeader(data: Bool = false, audioBytes: Int = 0, truncatedAt: Int? = nil) -> Data {
      func be(_ value: Int64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
      var bytes = Data("caff".utf8) + Data([0, 1, 0, 0])
      bytes += Data("desc".utf8) + be(32) + Data(count: 32)
      if data { bytes += Data("data".utf8) + be(-1) + Data(count: 4 + audioBytes) }
      return truncatedAt.map { Data(bytes.prefix($0)) } ?? bytes
    }

    private func shadowFile(_ contents: Data, in directory: URL, index: Int = 0) throws -> URL {
      let url = directory.appending(path: "\(memo(1).uuidString)-\(index).caf")
      try contents.write(to: url)
      return url
    }

    @Test func aShadowIsEmptyOnlyWhenAValidCafProvesItHoldsNoAudio() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }

      let headerOnly = try shadowFile(cafHeader(), in: directory, index: 0)
      let emptyData = try shadowFile(cafHeader(data: true), in: directory, index: 1)
      let cutInsideTheHeader = try shadowFile(cafHeader(truncatedAt: 20), in: directory, index: 2)
      #expect(
        SegmentWriter.recover(shadow: headerOnly, sampleRate: 16_000) == .empty, "a CAF that ends before its data")
      #expect(SegmentWriter.recover(shadow: emptyData, sampleRate: 16_000) == .empty, "a data chunk with no audio")
      #expect(
        SegmentWriter.recover(shadow: cutInsideTheHeader, sampleRate: 16_000) == .empty, "cut inside a header chunk")
    }

    @Test func aShadowThatIsNotProvenEmptyIsFailedAndKept() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let zeroes = try shadowFile(Data(count: 100), in: directory, index: 0)  // short, but not a CAF at all
      let garbage = try shadowFile(Data(repeating: 7, count: 9_000), in: directory, index: 1)
      let withAudioBytes = try shadowFile(cafHeader(data: true, audioBytes: 64), in: directory, index: 2)
      let unreadable = try shadowFile(cafHeader(), in: directory, index: 3)
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

      for shadow in [zeroes, garbage, withAudioBytes, unreadable] {
        #expect(SegmentWriter.recover(shadow: shadow, sampleRate: 16_000) == .failed, "\(shadow.lastPathComponent)")
      }
    }

    // MARK: Sweep

    @Test func theSweepRecoversTheKilledSegmentAndTheTakeGrowsByIt() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let id = memo(1)
      var item = voiceItem(id)
      item.create = .uploaded
      item.createMayHaveLanded = true
      let entries = try (0..<2).map { index in
        let closed = try writeSegment(id, index, seconds: 1, in: directory)
        closed.close()
        return OutboxEntry(
          segment: ClosedSegment(memoID: id, index: index, fileURL: closed.url, byteCount: 5, duration: 1),
          sequence: index,
          state: .uploaded, attempts: 0)
      }
      let open = try writeSegment(id, 2, seconds: 5, in: live)
      try killed(open, into: directory)
      open.close()
      let harness = try await OutboxHarness(record: OutboxRecord(entries: entries, items: [item], nextSequence: 2))

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.recovered.map(\.lastPathComponent) == ["\(id.uuidString)-2.m4a"])
      #expect(report.adopted.map(\.lastPathComponent) == ["\(id.uuidString)-2.m4a"])
      #expect(report.quarantined.isEmpty)
      #expect(await harness.outbox.memos().first?.segmentCount == 3, "the killed segment is part of the take")
      #expect(!names(directory).contains { $0.hasSuffix(".caf") }, "the shadow is gone once its m4a plays")
      let recovered = try #require(await harness.outbox.entries().first { $0.segment.index == 2 })
      #expect(abs(recovered.segment.duration - 5) < 0.5)

      await harness.outbox.settled()
      #expect(await harness.uploader.uploaded.map(\.index).sorted() == [2])
      #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 3)])
      await harness.outbox.shutdown()
    }

    @Test func aTakeKilledBeforeItsFirstSegmentSavedComesBackWithTheRecoveredSegment() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let id = memo(1)
      let open = try writeSegment(id, 0, seconds: 5, in: live)
      try killed(open, into: directory)
      open.close()
      let harness = try await OutboxHarness(record: OutboxRecord(items: [voiceItem(id)]))
      #expect(await harness.outbox.items().isEmpty, "a take with no segment is dropped on load")

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.adopted.count == 1 && report.quarantined.isEmpty)
      #expect(await harness.outbox.items().map(\.memoID) == [id], "the take is back, with its mode and start")
      #expect(await harness.outbox.memos().first?.segmentCount == 1)
      #expect(await harness.store.load().items.map(\.memoID) == [id], "saved before anything goes up")

      await harness.outbox.settled()
      #expect(await harness.uploader.created.map(\.memoID) == [id])
      #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 1)])
      await harness.outbox.shutdown()
    }

    @Test func anEmptyTakeWhoseShadowCouldNotBeRecoveredStaysInEverySaveUntilItCan() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let id = memo(1)
      // A shadow that cannot be read now (the next launch may read it): the take's audio is not known to be absent.
      try Data(repeating: 7, count: 9_000).write(to: directory.appending(path: "\(id.uuidString)-0.caf"))
      let harness = try await OutboxHarness(record: OutboxRecord(items: [voiceItem(id)]))

      await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))
      await harness.outbox.flush()  // any later save, whatever caused it

      #expect(await harness.store.load().items.map(\.memoID) == [id], "the take is kept on disk for the next launch")
      #expect(await harness.outbox.queue().isEmpty, "and shows nowhere: it is not a take that can be sent")
      #expect(await harness.outbox.items().isEmpty)

      // The next launch reads the shadow at last.
      let relaunched = try await OutboxHarness(record: await harness.store.load())
      let live = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: live) }
      try FileManager.default.removeItem(at: directory.appending(path: "\(id.uuidString)-0.caf"))
      let open = try writeSegment(id, 0, seconds: 3, in: live)
      try killed(open, into: directory)
      open.close()
      let report = await relaunched.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))
      #expect(report.adopted.count == 1)
      #expect(await relaunched.outbox.items().map(\.memoID) == [id])
      await harness.outbox.shutdown()
      await relaunched.outbox.shutdown()
    }

    @Test func anEmptyTakeIsDroppedFromTheSaveOnceNothingOfItRemains() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let harness = try await OutboxHarness(record: OutboxRecord(items: [voiceItem(memo(1))]))

      await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))
      await harness.outbox.flush()

      #expect(await harness.store.load().items.isEmpty, "no file names it: absence of audio is established")
      await harness.outbox.shutdown()
    }

    /// A take with segments 0 and 1 uploaded whose queue was last saved before its open segment 2 closed: the sweep must bring 2 back.
    private func recoveredTake(_ id: MemoID, in directory: URL) throws -> OutboxRecord {
      var item = voiceItem(id)
      item.create = .uploaded
      item.createMayHaveLanded = true
      let entries = try (0..<2).map { index in
        let closed = try writeSegment(id, index, seconds: 1, in: directory)
        closed.close()
        return OutboxEntry(
          segment: ClosedSegment(memoID: id, index: index, fileURL: closed.url, byteCount: 5, duration: 1),
          sequence: index, state: .uploaded, attempts: 0)
      }
      return OutboxRecord(entries: entries, items: [item], nextSequence: 2)
    }

    @Test func aTakeIsNotCompletedWithoutItsTailWhileTheTailShadowCannotBeRecovered() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let id = memo(1)
      let record = try recoveredTake(id, in: directory)
      try Data(repeating: 7, count: 9_000).write(to: directory.appending(path: "\(id.uuidString)-2.caf"))
      let harness = try await OutboxHarness(record: record)

      await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))
      await harness.outbox.settled()

      #expect(await harness.uploader.completed.isEmpty, "the take would go up without its last seconds")
      let row = try #require(await harness.outbox.queue().first)
      guard case .failed(let retryAt, let reason) = row.status else {
        Issue.record("expected a stalled row, got \(row.status)")
        return
      }
      #expect(retryAt == nil && reason?.contains("could not be recovered") == true, "and the queue says why")

      // Sending it as it is stays the user's decision: retry now releases the hold.
      await harness.outbox.retryNow(id)
      await harness.outbox.settled()
      #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 2)])
      await harness.outbox.shutdown()
    }

    @Test func aTakeWhoseTailShadowIsRecoveredIsNotHeld() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let id = memo(1)
      let record = try recoveredTake(id, in: directory)
      let open = try writeSegment(id, 2, seconds: 2, in: live)
      try killed(open, into: directory)
      open.close()
      let harness = try await OutboxHarness(record: record)

      await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))
      await harness.outbox.settled()

      #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 3)])
      await harness.outbox.shutdown()
    }

    @Test func aTakeWithNothingOnDiskStaysDropped() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let harness = try await OutboxHarness(record: OutboxRecord(items: [voiceItem(memo(1))]))

      await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(await harness.outbox.items().isEmpty)
      await harness.outbox.shutdown()
    }

    @Test func aRecoveredSegmentOfNoTakeIsQuarantinedPlayableNotDeleted() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let open = try writeSegment(memo(9), 0, seconds: 3, in: live)
      try killed(open, into: directory)
      open.close()
      let harness = try await OutboxHarness()

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.recovered.count == 1 && report.quarantined.count == 1)
      let kept = directory.appending(path: "quarantine/\(memo(9).uuidString)-0.m4a")
      #expect(Outbox.inspectAudioFile(kept) != nil, "what the owner can recover from Settings plays")
      #expect(names(directory) == ["quarantine"])
      await harness.outbox.shutdown()
    }

    @Test func aShadowIsNotRecoveredOverASegmentAQuarantinedQueueNames() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let id = memo(1)
      let open = try writeSegment(id, 0, seconds: 3, in: live)
      try killed(open, into: directory)
      open.close()
      // The set-aside queue names the unreadable m4a: replacing it would destroy what that queue can still be read against.
      let m4a = directory.appending(path: "\(id.uuidString)-0.m4a")
      let before = try Data(contentsOf: m4a)
      let queueFile = directory.appending(path: "outbox.quarantined-1.json")
      try Data("{ \"entries\": [{\"fileURL\": \"\(m4a.path)\"}".utf8).write(to: queueFile)
      let outbox = try await Outbox(
        store: HeldQueueStore(files: [queueFile]), uploader: TestUploader(), clock: ManualClock())

      let report = await outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(try Data(contentsOf: m4a) == before, "the named file is untouched")
      #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(id.uuidString)-0.caf").path))
      #expect(report.recovered.isEmpty && report.adopted.isEmpty && report.quarantined.isEmpty)
      #expect(Set(report.kept.map(\.lastPathComponent)).isSuperset(of: ["\(id.uuidString)-0.caf"]))
      await outbox.shutdown()
    }

    @Test func aSetAsideQueueThatCannotBeReadKeepsEveryShadowUntouched() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let open = try writeSegment(memo(1), 0, seconds: 3, in: live)
      try killed(open, into: directory)
      open.close()
      let missing = directory.appending(path: "outbox.quarantined-gone.json")  // may name anything
      let outbox = try await Outbox(
        store: HeldQueueStore(files: [missing]), uploader: TestUploader(), clock: ManualClock())

      let report = await outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.recovered.isEmpty)
      #expect(names(directory).filter { $0.hasSuffix(".caf") }.count == 1, "the shadow is still there")
      await outbox.shutdown()
    }

    @Test func aShadowBesideAPlayableM4aOfTheSameLengthIsRedundantAndGoes() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let id = memo(1)
      let writer = try writeSegment(id, 0, seconds: 2, in: directory)
      // Killed between the m4a's close and the shadow's removal: both files, the m4a whole.
      let shadow = SegmentShadow.url(of: writer.url)
      let copy = directory.appending(path: "copy.caf")
      try FileManager.default.copyItem(at: shadow, to: copy)
      writer.close()
      try FileManager.default.moveItem(at: copy, to: shadow)
      let harness = try await OutboxHarness()

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.recovered.isEmpty && report.stuck.isEmpty)
      #expect(!names(directory).contains { $0.hasSuffix(".caf") })
      let kept = directory.appending(path: "quarantine/\(writer.url.lastPathComponent)")
      #expect(
        Outbox.inspectAudioFile(kept) != nil, "the m4a itself is untouched (no take holds it, so it is kept aside)")
      await harness.outbox.shutdown()
    }

    @Test func aShadowBesideAPlayableM4aOfAnotherLengthIsNotProvenADuplicateAndStays() async throws {
      let live = try temporaryDirectory()
      let directory = try temporaryDirectory()
      defer { for url in [live, directory] { try? FileManager.default.removeItem(at: url) } }
      let id = memo(1)
      let longer = try writeSegment(id, 0, seconds: 6, in: live)
      try killed(longer, into: directory)  // a 6 s shadow ...
      longer.close()
      // ... beside a playable 2 s m4a of the same name
      let shorter = try writeSegment(id, 1, seconds: 2, in: directory)
      shorter.close()
      let m4a = directory.appending(path: "\(id.uuidString)-0.m4a")
      try FileManager.default.removeItem(at: m4a)
      try FileManager.default.moveItem(at: directory.appending(path: "\(id.uuidString)-1.m4a"), to: m4a)
      let harness = try await OutboxHarness()

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      let shadow = directory.appending(path: "\(id.uuidString)-0.caf")
      #expect(
        FileManager.default.fileExists(atPath: shadow.path), "6 s of audio that no playable file is known to hold")
      #expect(report.stuck == [shadow])
      await harness.outbox.shutdown()
    }

    @Test func anUnreadableShadowIsKeptForTheNextLaunch() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let shadow = directory.appending(path: "\(memo(1).uuidString)-0.caf")
      try Data(repeating: 7, count: 9_000).write(to: shadow)
      let harness = try await OutboxHarness()

      let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

      #expect(report.stuck == [shadow])
      #expect(FileManager.default.fileExists(atPath: shadow.path))
      await harness.outbox.shutdown()
    }
  }
#endif
