import Foundation

/// The launch arguments of every UI test that runs on the fake stack. The sample memos are relative to the clock, so the
/// tests pin it to noon today: History then looks the same at 00:30 and at 14:00 (a memo from 90 minutes ago is on
/// another day for the first hour and a half after midnight, below the fold of a list the tests do not scroll).
enum SampleClock {
  static var arguments: [String] {
    let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    return ["-IrisFakeCapture", "-IrisSampleNow", noon.formatted(.iso8601)]
  }
}
