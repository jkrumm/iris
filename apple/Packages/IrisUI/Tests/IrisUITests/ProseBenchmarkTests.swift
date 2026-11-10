#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// Replaces the competitors' harness (`docs/research/2026-11-10-prose-renderer-bench`, `BenchMV`) for the renderer we kept:
  /// the fixture reply as 20-character growing snapshots, each pushed into an `NSHostingView` 390 pt wide with the app's 16 pt
  /// callout, laid out, measured (`fittingSize`) and followed by one run-loop turn. Three variants:
  ///
  /// - A: the whole string, unbuffered, no chunk reuse: one Textual view per text run, rebuilt for every snapshot (Textual
  ///   0.5.0 as shipped). Every second snapshot (and the last) is timed.
  /// - B: the same renderer behind `StreamBuffer`, snapshots arriving 50 ms apart on a simulated clock.
  /// - C: the final design (chunks, stabilized tail, incremental model) behind the same buffer and clock, ended by an update with
  ///   `isStreaming == false` that is timed on its own as the stream end.
  ///
  /// It asserts structure only; the numbers go to the output and to `prose-benchmark.md` in the temporary directory.
  @MainActor
  @Suite(.serialized)
  struct ProseBenchmarkTests {
    private struct Run {
      var name: String
      var samples: [Double] = []
      var heights: [CGFloat] = []
      /// The update with `isStreaming == false` that ends a stream (for C it remounts the text blocks).
      var streamEnd: Double?
      var finalHeight: CGFloat = 0
      var updates: Int { samples.count }
    }

    private static let warmUp = 10
    private static let arrival = Duration.milliseconds(50)
    private static let unbufferedStride = 2

    private let clock = ContinuousClock()

    private func whole(_ markdown: String) -> MessageContentView {
      MessageContentView(
        markdown: markdown, isStreaming: false, isBuffered: true,
        prepared: MessageBlock.tracked(markdown, chunked: false).blocks.identified)
    }

    private func streaming(_ markdown: String, isStreaming: Bool) -> MessageContentView {
      MessageContentView(markdown: markdown, isStreaming: isStreaming, isBuffered: false, prepared: nil)
    }

    /// Shows `view`, lays it out, reads the height, turns the run loop once and lays out again: one timed update.
    private func timedUpdate<V: View>(_ view: V, in host: HostingMeasure, into run: inout Run) {
      let start = clock.now
      host.show(view)
      _ = host.layout()
      host.spinRunLoop()
      let height = host.layout()
      run.samples.append(milliseconds(clock.now - start))
      run.heights.append(height)
    }

    private func milliseconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func variantA(_ snapshots: [String]) -> Run {
      let host = HostingMeasure()
      var run = Run(name: "A whole string, unbuffered (every \(Self.unbufferedStride)nd snapshot)")
      for (index, snapshot) in snapshots.enumerated()
      where index % Self.unbufferedStride == 0 || index == snapshots.count - 1 {
        timedUpdate(whole(snapshot), in: host, into: &run)
      }
      run.finalHeight = host.height(of: whole(snapshots[snapshots.count - 1]))
      return run
    }

    /// Feeds `snapshots` 50 ms apart through a `StreamBuffer`; every publish is rendered by `render`, the end of the stream by
    /// `finish`. A deadline that falls before the next arrival publishes the latest text at the deadline.
    private func buffered<V: View, F: View>(
      _ snapshots: [String], name: String, render: (String) -> V, finish: (String) -> F
    ) -> Run {
      let host = HostingMeasure()
      var run = Run(name: name)
      var buffer = StreamBuffer()
      var deadline: Duration?
      var latest = ""
      for (index, snapshot) in snapshots.enumerated() {
        let now = Self.arrival * index
        if let due = deadline, due <= now {
          deadline = nil
          if case .publish(let text) = buffer.publish(latest, at: due) {
            timedUpdate(render(text), in: host, into: &run)
          }
        }
        latest = snapshot
        switch buffer.offer(snapshot, at: now) {
        case .publish(let text):
          deadline = nil
          timedUpdate(render(text), in: host, into: &run)
        case .wait(let until):
          deadline = deadline ?? until
        }
      }
      var end = Run(name: name)
      timedUpdate(finish(snapshots[snapshots.count - 1]), in: host, into: &end)
      run.streamEnd = end.samples.first
      run.finalHeight = host.height(of: finish(snapshots[snapshots.count - 1]))
      return run
    }

    private func row(_ run: Run) -> String {
      let samples = Array(run.samples.dropFirst(Self.warmUp)).sorted()
      guard !samples.isEmpty else { return "| \(run.name) | 0 | | | | | | |" }
      func percentile(_ p: Double) -> Double {
        samples[min(max(Int((p / 100 * Double(samples.count)).rounded(.up)) - 1, 0), samples.count - 1)]
      }
      func f(_ value: Double) -> String { String(format: "%.2f", value) }
      let total = samples.reduce(0, +)
      return "| \(run.name) | \(samples.count) | \(f(total / Double(samples.count))) | \(f(percentile(50))) "
        + "| \(f(percentile(95))) | \(f(percentile(99))) | \(f(samples.last ?? 0)) | \(f(total)) |"
    }

    @Test("benchmark: whole string vs buffered vs chunked, incremental and buffered, on the streamed fixture")
    func benchmark() throws {
      let snapshots = ProseFixture.snapshots(step: 20)
      #expect(snapshots.count > 100)
      let a = variantA(snapshots)
      let b = buffered(
        snapshots, name: "B whole string behind the buffer (50 ms arrivals)", render: { whole($0) },
        finish: { whole($0) })
      let c = buffered(
        snapshots, name: "C final design: chunks + tail + buffer (50 ms arrivals)",
        render: { streaming($0, isStreaming: true) }, finish: { streaming($0, isStreaming: false) })

      let configuration: String
      #if DEBUG
        configuration = "debug"
      #else
        configuration = "release"
      #endif
      let table =
        ([
          "Prose renderer benchmark: \(snapshots.count) snapshots of \(ProseFixture.reply.count) characters, 390 pt, "
            + "16 pt callout, \(configuration) build, warm-up \(Self.warmUp) dropped, times in ms per timed update.",
          "",
          "| variant | updates | mean | p50 | p95 | p99 | max | total |",
          "|-|-|-|-|-|-|-|-|",
          row(a), row(b), row(c),
          "",
          "Publishes: B \(b.updates), C \(c.updates) of \(snapshots.count) arrivals. "
            + "Final heights: A \(a.finalHeight), B \(b.finalHeight), C \(c.finalHeight) pt. "
            + "Stream end (the update with isStreaming false): B "
            + "\(String(format: "%.2f", b.streamEnd ?? 0)) ms, C \(String(format: "%.2f", c.streamEnd ?? 0)) ms (remount).",
        ]).joined(separator: "\n")
      print(table)
      try table.write(
        toFile: (NSTemporaryDirectory() as NSString).appendingPathComponent("prose-benchmark.md"), atomically: true,
        encoding: .utf8)

      for run in [a, b, c] {
        #expect(run.heights.allSatisfy { $0 > 0 }, "\(run.name) has a height of zero")
        #expect((run.heights.last ?? 0) > (run.heights.first ?? .infinity), "\(run.name) grows")
        #expect(run.finalHeight > 0)
      }
      #expect(abs(c.finalHeight - a.finalHeight) <= 1, "C ends \(c.finalHeight) vs A \(a.finalHeight)")
      #expect(abs(b.finalHeight - a.finalHeight) <= 1)
      #expect(c.streamEnd != nil)
    }

    @Test("the last update of the streamed variant is the one with isStreaming false")
    func lastUpdateIsFinal() {
      let full = ProseFixture.reply
      var model = StreamingReplyModel()
      for snapshot in ProseFixture.snapshots(step: 400).dropLast() {
        model.update(markdown: snapshot, isStreaming: true)
      }
      #expect(model.update(markdown: full, isStreaming: false) == MessageBlock.split(full).identified)
    }
  }
#endif
