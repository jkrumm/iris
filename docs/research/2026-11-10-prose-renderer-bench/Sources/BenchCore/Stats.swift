import Foundation

public struct BenchResult {
    public let name: String
    /// Per-update durations in milliseconds, warm-up already dropped.
    public let samples: [Double]

    public var mean: Double { samples.reduce(0, +) / Double(samples.count) }
    public var total: Double { samples.reduce(0, +) }
    public var max: Double { samples.max() ?? 0 }
    public func percentile(_ p: Double) -> Double {
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }
}

public func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Runs `pass` three times, each returning the per-update times of the whole stream, and reports
/// the pass with the median total.
public func report(name: String, warmup: Int = 10, passes: [[Double]]) {
    let results = passes.map { BenchResult(name: name, samples: Array($0.dropFirst(warmup))) }
    let ranked = results.sorted { $0.total < $1.total }
    let median = ranked[ranked.count / 2]
    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    print("RESULT \(name) updates=\(median.samples.count) (+\(warmup) warm-up) passes=\(passes.count)")
    print("  pass totals ms: " + results.map { f($0.total) }.joined(separator: " / "))
    print("  median pass: mean=\(f(median.mean)) p50=\(f(median.percentile(50))) p95=\(f(median.percentile(95))) p99=\(f(median.percentile(99))) max=\(f(median.max)) total=\(f(median.total)) ms")
}
