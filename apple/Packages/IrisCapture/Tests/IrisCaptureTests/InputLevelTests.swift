#if canImport(AVFAudio)
  import Foundation
  import Testing

  @testable import IrisCapture

  /// The take screen's meter: a perceptual scale where silence is empty, normal speech sits mid-high and clipping fills it.
  struct InputLevelTests {
    /// `count` samples of a square wave at `amplitude` (its RMS is the amplitude), below the clipping peak.
    private func buffer(amplitude: Float, count: Int = 256) -> [Float] {
      (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private func decibels(_ value: Float) -> Float { pow(10, value / 20) }

    @Test("silence reads zero, whether it is exact or the room tone below the floor")
    func silence() {
      #expect(InputLevel.meter([Float](repeating: 0, count: 256)) == 0)
      #expect(InputLevel.meter([]) == 0)
      #expect(InputLevel.meter(buffer(amplitude: decibels(-60))) == 0)
    }

    @Test("normal speech (−35 to −20 dBFS) lands mid-high, where linear RMS left it near the floor")
    func speech() {
      let quiet = InputLevel.meter(buffer(amplitude: decibels(-35)))
      let normal = InputLevel.meter(buffer(amplitude: decibels(-30)))
      let loud = InputLevel.meter(buffer(amplitude: decibels(-20)))
      #expect(abs(normal - 0.5) < 0.01)
      #expect(quiet > 0.3 && quiet < normal)
      #expect(loud > 0.7 && loud < 1)
      #expect(normal > 10 * decibels(-30), "the linear value would be 0.03")
    }

    @Test("the meter only ever rises with the level, and reaches the ceiling")
    func monotonic() {
      let levels = stride(from: Float(-70), through: -10, by: 5).map { InputLevel.meter(rms: decibels($0)) }
      #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
      #expect(levels.first == 0)
      #expect(abs((levels.last ?? 0) - 1) < 0.001)
      #expect(InputLevel.meter(rms: 0.9) == 1)
    }

    @Test("a clipped sample reads full scale whatever the rest of the buffer says")
    func clipping() {
      var samples = buffer(amplitude: decibels(-45))
      samples[10] = 1
      #expect(InputLevel.meter(samples) == 1)
      samples[10] = -1
      #expect(InputLevel.meter(samples) == 1)
    }
  }
#endif
