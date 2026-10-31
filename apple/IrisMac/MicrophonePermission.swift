import AVFAudio
import Foundation

/// Where the microphone permission stands.
enum MicrophoneAccess: Equatable, Sendable {
  case undetermined
  case granted
  case denied
}

/// The system's microphone permission (TCC), behind a port so the panel's start path tests without a prompt.
/// Production: `SystemMicrophonePermission`. Fake: `FakeMicrophonePermission`.
protocol MicrophonePermission: Sendable {
  var access: MicrophoneAccess { get }
  /// Shows the system prompt when the answer is still open; the answer.
  func request() async -> Bool
}

struct SystemMicrophonePermission: MicrophonePermission {
  var access: MicrophoneAccess {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: .granted
    case .denied: .denied
    default: .undetermined
    }
  }

  func request() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }
}

/// A fixed answer for tests and `-IrisFakeData` (an unsigned build must never raise the prompt).
final class FakeMicrophonePermission: MicrophonePermission, @unchecked Sendable {
  private let lock = NSLock()
  private var current: MicrophoneAccess
  private let answer: Bool
  private var asked = 0

  init(_ access: MicrophoneAccess = .granted, answer: Bool = true) {
    current = access
    self.answer = answer
  }

  var access: MicrophoneAccess { lock.withLock { current } }
  /// How many times the prompt was requested.
  var requests: Int { lock.withLock { asked } }

  func request() async -> Bool {
    lock.withLock {
      asked += 1
      current = answer ? .granted : .denied
    }
    return answer
  }
}
