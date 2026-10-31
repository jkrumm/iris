#if canImport(AVFAudio)
  import Foundation
  import Synchronization

  /// Closes the recorder's segments in order, off the recorder's actor, and publishes each as a `.segmentClosed` event.
  ///
  /// The rules, all about not losing a recorded second and not promising one that is not there:
  /// - A segment is published only after its writer has finished and the file reads back.
  /// - A file that ends where the encoder stopped (the writer reported an error) is published with the duration it really
  ///   holds, followed by `.failed`: the take ends there, with that prefix.
  /// - After any failed close no later segment of the take is published (the outbox would wait for the missing index, and
  ///   the memo would claim audio it does not hold). Their writers are still finished and their files stay on disk for the next
  ///   launch's sweep. Nothing is deleted.
  /// A segment whose writer could not even be created: nothing is held, and closing it reports why, in order with the others.
  struct UnwritableSegment: ClosableSegment {
    let url: URL
    let reason: String
    func finish() async -> SegmentWriter.Outcome {
      SegmentWriter.Outcome(byteCount: 0, readableFrames: 0, error: reason)
    }
  }

  final class SegmentCloser: Sendable {
    private let emit: @Sendable (CaptureEvent) -> Void
    private let sampleRate: Int
    private let halted = Mutex(false)
    private let chain = Mutex<Task<Void, Never>?>(nil)

    init(sampleRate: Int, emit: @escaping @Sendable (CaptureEvent) -> Void) {
      self.sampleRate = sampleRate
      self.emit = emit
    }

    /// A new take publishes again.
    func reset() { halted.withLock { $0 = false } }

    /// Queues the close behind the earlier ones and returns at once, so the next segment starts without a gap.
    func close(
      _ segment: any ClosableSegment, index: Int, memoID: MemoID, duration: TimeInterval, reason: RotationReason
    ) {
      chain.withLock { previous in
        let before = previous
        // Owned by the closer; `idle()` awaits the last one and each one ends when its writer has finished.
        previous = Task {
          await before?.value
          await self.run(segment, index: index, memoID: memoID, duration: duration, reason: reason)
        }
      }
    }

    /// Returns once every close queued so far has published or given up.
    func idle() async {
      let last = chain.withLock { $0 }
      await last?.value
    }

    private func run(
      _ segment: any ClosableSegment, index: Int, memoID: MemoID, duration: TimeInterval, reason: RotationReason
    ) async {
      let outcome = await segment.finish()
      if let error = outcome.error { Log.capture.error("segment \(index) finish: \(error, privacy: .public)") }
      if halted.withLock({ $0 }) {
        Log.capture.error("segment \(index) left on disk: an earlier segment of the take did not close")
        return
      }
      guard outcome.readableFrames > 0 else {
        halted.withLock { $0 = true }
        emit(.failed(reason: "segment finish failed"))
        return
      }
      let truncated = outcome.error != nil
      let held = TimeInterval(outcome.readableFrames) / TimeInterval(sampleRate)
      let closed = ClosedSegment(
        memoID: memoID, index: index, fileURL: segment.url, byteCount: outcome.byteCount,
        duration: truncated ? min(duration, held) : duration)
      emit(.segmentClosed(closed, reason: reason))
      if truncated {
        halted.withLock { $0 = true }
        emit(.failed(reason: "segment finish failed"))
      }
    }
  }
#endif
