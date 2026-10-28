import Foundation

/// The memo id, a UUID v4 minted at record start (it doubles as the trace id).
/// Defined locally so IrisCapture does not depend on IrisCore.
public typealias MemoID = UUID

/// Why a segment was closed before (or exactly at) its full length.
public enum RotationReason: String, Sendable, Equatable, Codable, CaseIterable {
  case duration
  case micSwitch
  case interruption
  case configurationChange
  case stop
}

/// A finished, immutable segment file ready for the outbox.
public struct ClosedSegment: Sendable, Equatable, Hashable, Codable {
  public let memoID: MemoID
  /// Contiguous from 0 per memo.
  public let index: Int
  public let fileURL: URL
  public let byteCount: Int
  public let duration: TimeInterval

  public init(memoID: MemoID, index: Int, fileURL: URL, byteCount: Int, duration: TimeInterval) {
    self.memoID = memoID
    self.index = index
    self.fileURL = fileURL
    self.byteCount = byteCount
    self.duration = duration
  }
}

/// Events published by a `SegmentRecorder`.
public enum CaptureEvent: Sendable, Equatable {
  case started(MemoID)
  case segmentClosed(ClosedSegment, reason: RotationReason)
  /// Emitted after the final segment was flushed. `segmentCount` is the total for the memo.
  case stopped(MemoID, segmentCount: Int)
  case failed(reason: String)
}

public enum PortKind: String, Sendable, Equatable, Codable {
  case builtInMic
  case bluetoothHFP
  case bluetoothLE
  case headsetMic
  case carAudio
  case usb
  case other
}

/// A selectable audio input (or, for fingerprints, an output) port.
public struct InputPort: Sendable, Equatable, Hashable, Codable {
  public let uid: String
  public let name: String
  public let kind: PortKind

  public init(uid: String, name: String, kind: PortKind) {
    self.uid = uid
    self.name = name
    self.kind = kind
  }
}

/// A point-in-time view of the audio route.
public struct RouteSnapshot: Sendable, Equatable {
  public let availableInputs: [InputPort]
  public let currentInput: InputPort?
  public let outputUIDs: [String]

  public init(availableInputs: [InputPort], currentInput: InputPort?, outputUIDs: [String]) {
    self.availableInputs = availableInputs
    self.currentInput = currentInput
    self.outputUIDs = outputUIDs
  }

  /// Identifies the situation a rule applies to (for example "AirPods + car"): the sorted output port UIDs.
  /// The input is deliberately excluded, so a preference survives the input switching under it.
  public var fingerprint: String {
    outputUIDs.sorted().joined(separator: "+")
  }
}

public enum RouteChangeReason: String, Sendable, Equatable {
  case deviceAppeared
  case deviceDisappeared
  case userSelection
  case categoryChange
  case other
}

public struct RouteChange: Sendable, Equatable {
  public let snapshot: RouteSnapshot
  public let reason: RouteChangeReason

  public init(snapshot: RouteSnapshot, reason: RouteChangeReason) {
    self.snapshot = snapshot
    self.reason = reason
  }
}

public enum InterruptionEvent: Sendable, Equatable {
  case began
  case ended(shouldResume: Bool)
}

public enum CaptureError: Error, Sendable, Equatable {
  case alreadyRecording
  case notRecording
  case inputUnavailable(uid: String)
  case engineFailure(String)
  case sessionFailure(String)
  /// The recorder failed mid-take (a write error, the engine would not restart) and no segment was kept.
  case recordingFailed(String)
}
