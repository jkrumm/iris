import Foundation
import Testing

@testable import IrisCapture

struct SegmentRotationTests {
  let policy = SegmentRotationPolicy()  // 16 kHz, 10 s -> 160_000 frames

  /// Feeds `total` frames in buffers of `bufferFrames`, like the tap would, and collects the closes.
  private func closes(feeding total: Int, bufferFrames: Int, rotator: inout SegmentRotator) -> [SegmentAction] {
    var actions: [SegmentAction] = []
    var remaining = total
    while remaining > 0 {
      let frames = min(remaining, bufferFrames)
      actions += rotator.append(frames: frames)
      remaining -= frames
    }
    return actions
  }

  @Test func policyCountsFramesNotWallClock() {
    #expect(policy.framesPerSegment == 160_000)
    #expect(policy.duration(frames: 160_000) == 10)
    let slow = SegmentRotationPolicy(sampleRate: 8_000, segmentSeconds: 2)
    #expect(slow.framesPerSegment == 16_000)
    #expect(slow.duration(frames: 4_000) == 0.5)
  }

  @Test func closesExactlyOnTheBoundary() {
    var rotator = SegmentRotator(policy: policy)
    let actual1 = rotator.append(frames: 160_000)
    #expect(
      actual1 == [
        .write(segment: 0, frames: 160_000),
        .close(segment: 0, frames: 160_000, reason: .duration),
      ])
    // The boundary already closed the segment: stopping right after emits no empty segment.
    let actual2 = rotator.finish()
    #expect(actual2.isEmpty)
    #expect(rotator.closedCount == 1)
  }

  @Test func oneFrameShortStaysOpenUntilStop() {
    var rotator = SegmentRotator(policy: policy)
    let actual1 = rotator.append(frames: 159_999)
    #expect(actual1 == [.write(segment: 0, frames: 159_999)])
    let actual2 = rotator.finish()
    #expect(actual2 == [.close(segment: 0, frames: 159_999, reason: .stop)])
  }

  @Test func splitsABufferThatStraddlesTheBoundary() {
    var rotator = SegmentRotator(policy: policy)
    _ = rotator.append(frames: 100_000)
    let actual = rotator.append(frames: 100_000)
    #expect(
      actual == [
        .write(segment: 0, frames: 60_000),
        .close(segment: 0, frames: 160_000, reason: .duration),
        .write(segment: 1, frames: 40_000),
      ])
  }

  @Test func oneHugeBufferYieldsContiguousSegments() {
    var rotator = SegmentRotator(policy: policy)
    let actions = rotator.append(frames: 350_000)
    #expect(
      actions == [
        .write(segment: 0, frames: 160_000),
        .close(segment: 0, frames: 160_000, reason: .duration),
        .write(segment: 1, frames: 160_000),
        .close(segment: 1, frames: 160_000, reason: .duration),
        .write(segment: 2, frames: 30_000),
      ])
  }

  @Test(arguments: [1, 7, 480, 4_096, 16_000, 160_000, 200_000])
  func totalsAreIndependentOfBufferSize(bufferFrames: Int) {
    var rotator = SegmentRotator(policy: policy)
    var actions = closes(feeding: 400_000, bufferFrames: bufferFrames, rotator: &rotator)
    actions += rotator.finish()

    let closed = actions.compactMap { action -> (Int, Int)? in
      guard case .close(let index, let frames, _) = action else { return nil }
      return (index, frames)
    }
    #expect(closed.map(\.0) == [0, 1, 2])
    #expect(closed.map(\.1) == [160_000, 160_000, 80_000])

    var written = 0
    for case .write(_, let frames) in actions { written += frames }
    #expect(written == 400_000)
  }

  @Test func micSwitchMidSegmentRollsOver() {
    var rotator = SegmentRotator(policy: policy)
    _ = rotator.append(frames: 48_000)
    let actual1 = rotator.rotate(for: .micSwitch)
    #expect(actual1 == [.close(segment: 0, frames: 48_000, reason: .micSwitch)])
    // The next segment starts fresh, with the next index and a full 10 s of room.
    let actual2 = rotator.append(frames: 160_000)
    #expect(actual2.first == .write(segment: 1, frames: 160_000))
    #expect(rotator.closedCount == 2)
  }

  @Test(arguments: [RotationReason.micSwitch, .interruption, .configurationChange])
  func eventDrivenRotationClosesThePartialSegment(reason: RotationReason) {
    var rotator = SegmentRotator(policy: policy)
    _ = rotator.append(frames: 1)
    let actual = rotator.rotate(for: reason)
    #expect(actual == [.close(segment: 0, frames: 1, reason: reason)])
  }

  @Test(arguments: [RotationReason.micSwitch, .interruption, .configurationChange, .stop])
  func rotatingWithoutFramesEmitsNothingAndKeepsIndicesContiguous(reason: RotationReason) {
    var rotator = SegmentRotator(policy: policy)
    let actual1 = rotator.rotate(for: reason)
    #expect(actual1.isEmpty)
    let actual2 = rotator.rotate(for: reason)
    #expect(actual2.isEmpty)
    _ = rotator.append(frames: 10)
    let actual3 = rotator.rotate(for: .micSwitch)
    #expect(actual3 == [.close(segment: 0, frames: 10, reason: .micSwitch)])
    let actual4 = rotator.rotate(for: .micSwitch)
    #expect(actual4.isEmpty)
    _ = rotator.append(frames: 20)
    let actual5 = rotator.finish()
    #expect(actual5 == [.close(segment: 1, frames: 20, reason: .stop)])
  }

  @Test func rotatingRightAfterABoundaryEmitsNoEmptySegment() {
    var rotator = SegmentRotator(policy: policy)
    _ = rotator.append(frames: 160_000)
    let actual1 = rotator.rotate(for: .interruption)
    #expect(actual1.isEmpty)
    _ = rotator.append(frames: 5)
    let actual2 = rotator.finish()
    #expect(actual2 == [.close(segment: 1, frames: 5, reason: .stop)])
  }

  @Test func aTakeWithoutFramesEmitsNoSegment() {
    var rotator = SegmentRotator(policy: policy)
    let actual1 = rotator.append(frames: 0)
    #expect(actual1.isEmpty)
    let actual2 = rotator.finish()
    #expect(actual2.isEmpty)
    #expect(rotator.closedCount == 0)
  }

  @Test func stopFlushesTheFinalPartialSegmentAfterEarlierRotations() {
    var rotator = SegmentRotator(policy: policy)
    _ = rotator.append(frames: 170_000)  // closes 0 at the boundary, 10_000 frames open
    _ = rotator.rotate(for: .interruption)  // closes 1 with 10_000 frames
    _ = rotator.append(frames: 8_000)
    let actual = rotator.finish()
    #expect(actual == [.close(segment: 2, frames: 8_000, reason: .stop)])
    #expect(rotator.closedCount == 3)
  }
}
