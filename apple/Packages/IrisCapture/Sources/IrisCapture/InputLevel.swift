import Foundation

/// The take screen's meter value: the buffer's RMS on a perceptual (dB) scale, not the linear amplitude, which
/// leaves normal speech (about -30 dBFS, 0.03 linear) at a barely visible 3 %. Silence at or below ``floorDecibels``
/// reads 0, ``ceilingDecibels`` and above read 1, and a clipped sample (|x| at full scale) reads 1 whatever the RMS.
enum InputLevel {
  /// Quieter than this is the room, not the voice.
  static let floorDecibels: Float = -50
  /// Speech this loud already fills the meter.
  static let ceilingDecibels: Float = -10
  static let clippingPeak: Float = 0.99

  static func meter(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    if peak >= clippingPeak { return 1 }
    let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
    return meter(rms: meanSquare.squareRoot())
  }

  /// 0...1: linear in decibels between the floor and the ceiling.
  static func meter(rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(max((decibels - floorDecibels) / (ceilingDecibels - floorDecibels), 0), 1)
  }
}
