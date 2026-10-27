import Foundation

public struct SegmentRotationPolicy: Sendable, Equatable {
  public var sampleRate: Int
  public var segmentSeconds: Int

  public init(sampleRate: Int = 16_000, segmentSeconds: Int = 10) {
    self.sampleRate = sampleRate
    self.segmentSeconds = segmentSeconds
  }

  public var framesPerSegment: Int { sampleRate * segmentSeconds }

  public func duration(frames: Int) -> TimeInterval {
    Double(frames) / Double(sampleRate)
  }
}

/// What the recorder does with the frames it was fed.
public enum SegmentAction: Sendable, Equatable {
  /// Write the next `frames` frames of the incoming buffer into segment `segment`
  /// (open its file on the first write).
  case write(segment: Int, frames: Int)
  /// Close segment `segment`, which holds `frames` frames in total.
  case close(segment: Int, frames: Int, reason: RotationReason)
}

/// Pure rotation logic: counts frames (never wall-clock time) and tells the recorder where to cut.
///
/// A segment closes exactly when it reaches `framesPerSegment`, so a buffer straddling a boundary is
/// split. Indices advance only when a segment with frames closes, so they are contiguous from 0 and a
/// take with no frames emits no segment.
public struct SegmentRotator: Sendable {
  public let policy: SegmentRotationPolicy
  private var openFrames = 0
  private var nextIndex = 0

  public init(policy: SegmentRotationPolicy = SegmentRotationPolicy()) {
    self.policy = policy
  }

  /// Number of segments closed so far.
  public var closedCount: Int { nextIndex }

  public mutating func append(frames: Int) -> [SegmentAction] {
    var remaining = frames
    var actions: [SegmentAction] = []
    while remaining > 0 {
      let take = min(remaining, policy.framesPerSegment - openFrames)
      actions.append(.write(segment: nextIndex, frames: take))
      openFrames += take
      remaining -= take
      if openFrames == policy.framesPerSegment {
        actions.append(close(reason: .duration))
      }
    }
    return actions
  }

  /// Mic switch, interruption or engine configuration change.
  public mutating func rotate(for reason: RotationReason) -> [SegmentAction] {
    guard openFrames > 0 else { return [] }
    return [close(reason: reason)]
  }

  /// Flushes the final partial segment on stop.
  public mutating func finish() -> [SegmentAction] {
    rotate(for: .stop)
  }

  private mutating func close(reason: RotationReason) -> SegmentAction {
    let action = SegmentAction.close(segment: nextIndex, frames: openFrames, reason: reason)
    nextIndex += 1
    openFrames = 0
    return action
  }
}
