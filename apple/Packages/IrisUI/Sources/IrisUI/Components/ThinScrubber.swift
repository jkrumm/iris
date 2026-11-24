import SwiftUI

/// The timeline of the recording player and of the inline reply player: a thin divider track, an accent fill up to a small thumb. Dragging anywhere on it scrubs; `onEditing`
/// reports the start and the end of a drag. The system `Slider` has a large white pill thumb that reads as a placeholder.
struct ThinScrubber: View {
  @Binding var value: Double
  let upperBound: Double
  let onEditing: (Bool) -> Void
  @State private var isDragging = false

  private static let trackHeight: CGFloat = 3
  private static let thumbSize: CGFloat = 12
  private static let height: CGFloat = 28

  var body: some View {
    GeometryReader { proxy in
      let travel = max(proxy.size.width - Self.thumbSize, 1)
      let x = Self.thumbSize / 2 + travel * min(max(value / upperBound, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.divider).frame(height: Self.trackHeight)
        Capsule().fill(Theme.Accent.fill).frame(width: x, height: Self.trackHeight)
        Circle().fill(Theme.Accent.fill).frame(width: Self.thumbSize, height: Self.thumbSize)
          .offset(x: x - Self.thumbSize / 2)
      }
      .frame(maxHeight: .infinity)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            if !isDragging {
              isDragging = true
              onEditing(true)
            }
            value = Self.value(at: drag.location.x, travel: travel, upperBound: upperBound)
          }
          .onEnded { drag in
            value = Self.value(at: drag.location.x, travel: travel, upperBound: upperBound)
            isDragging = false
            onEditing(false)
          }
      )
    }
    .frame(height: Self.height)
  }

  private static func value(at x: CGFloat, travel: CGFloat, upperBound: Double) -> Double {
    let fraction = min(max((x - thumbSize / 2) / travel, 0), 1)
    return Double(fraction) * upperBound
  }
}

/// `m:ss`, or `h:mm:ss` from an hour on.
enum PlayerTime {
  static func string(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded(.down))
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
    let pair = rest < 10 ? "0\(rest)" : "\(rest)"
    if hours > 0 { return "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(pair)" }
    return "\(minutes):\(pair)"
  }
}
