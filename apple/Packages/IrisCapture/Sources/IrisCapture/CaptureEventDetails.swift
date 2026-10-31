import CryptoKit
import Foundation

#if canImport(AVFAudio)
  import AVFAudio
#endif

/// An OSStatus-style error code spelled as the four characters it encodes (`561145187` is `!rec`, `560557684` is `!int`), the
/// form the audio frameworks document their codes in. `nil` when the code is not four printable ASCII characters.
public enum FourCC {
  public static func string(from code: Int) -> String? {
    guard code > 0, code <= Int(UInt32.max) else { return nil }
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// How an audio port shows in an event. A port name can carry a person's name ("Anna's AirPods"), so only the generic names of the
/// phone's own ports are kept; any other name becomes a short stable hash that still tells two devices apart.
enum PortLabel {
  private static let generic: Set<String> = ["iPhone Microphone", "Speaker", "Receiver"]

  static func name(_ name: String) -> String {
    generic.contains(name)
      ? name : SHA256.hash(data: Data(name.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  /// `portType:name-or-hash`.
  static func describe(type: String, name: String) -> String {
    "\(type):\(Self.name(name))"
  }
}

/// The tap's level at 2 Hz: the RMS and the peak of everything that arrived since the last report, in dBFS (floored at -120).
/// Pure, so the cadence and the arithmetic are tested without audio.
struct LevelReporter {
  struct Level: Equatable {
    let rmsDecibels: Double
    let peakDecibels: Double
  }

  private let framesPerReport: Int
  private var sumOfSquares = 0.0
  private var peak: Float = 0
  private var frames = 0

  /// `sampleRate / 2` frames make one report, which is two a second.
  init(sampleRate: Int) {
    framesPerReport = max(1, sampleRate / 2)
  }

  mutating func add(_ samples: [Float]) -> Level? {
    for sample in samples {
      sumOfSquares += Double(sample * sample)
      peak = max(peak, abs(sample))
    }
    frames += samples.count
    guard frames >= framesPerReport else { return nil }
    let level = Level(
      rmsDecibels: Self.decibels(sqrt(sumOfSquares / Double(frames))), peakDecibels: Self.decibels(Double(peak)))
    sumOfSquares = 0
    peak = 0
    frames = 0
    return level
  }

  static func decibels(_ amplitude: Double) -> Double {
    guard amplitude > 0 else { return -120 }
    return (max(20 * log10(amplitude), -120) * 10).rounded() / 10
  }
}

/// The error of a failed call as event attributes.
public enum CaptureErrorDetail {
  /// Its domain and code, the code as four characters when it is one, its type.
  public static func attributes(of error: any Error) -> [String: CaptureEventValue] {
    let bridged = error as NSError
    var attributes: [String: CaptureEventValue] = [
      "error.domain": .string(bridged.domain), "error.code": .int(bridged.code),
      "error.type": .string(String(describing: type(of: error))),
    ]
    if let fourCC = FourCC.string(from: bridged.code) { attributes["error.fourcc"] = .string(fourCC) }
    return attributes
  }
}

extension CaptureEvents {
  /// `capture.session.error`: the call that failed (`setCategory`, `setActive`, `installTap`, `engine.start`), the error, and
  /// the state of the session and engine when it did, which is what tells a `!rec` from an `!int`.
  public func sessionError(call: String, error: any Error, engineRunning: Bool? = nil, memoID: MemoID? = nil) {
    var attributes = CaptureErrorDetail.attributes(of: error)
    attributes["call"] = .string(call)
    if let engineRunning { attributes["engine.running"] = .bool(engineRunning) }
    attributes.merge(SessionSnapshot.attributes()) { current, _ in current }
    event("capture.session.error", memoID: memoID, error: true, attributes)
  }
}

/// What the shared audio session looks like right now. Empty off iOS.
enum SessionSnapshot {
  static func attributes() -> [String: CaptureEventValue] {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      return [
        "session.category": .string(session.category.rawValue),
        "session.mode": .string(session.mode.rawValue),
        "session.options": .int(Int(session.categoryOptions.rawValue)),
        "session.other_audio_playing": .bool(session.isOtherAudioPlaying),
        "session.sample_rate": .double(session.sampleRate),
        "session.io_buffer_ms": .double((session.ioBufferDuration * 1000 * 10).rounded() / 10),
      ]
    #else
      return [:]
    #endif
  }

  /// `portType:name` of each port, joined by `,` (``PortLabel``: a personal name is hashed). The uid is left out.
  #if os(iOS)
    static func describe(_ ports: [AVAudioSessionPortDescription]) -> String {
      ports.map { PortLabel.describe(type: $0.portType.rawValue, name: $0.portName) }.joined(separator: ",")
    }
  #endif
}
