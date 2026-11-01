import AVFAudio
import Foundation
import IrisCapture
import Testing

@testable import Iris

/// The buffers the recognizer is fed: the tap's 16 kHz mono floats in whatever format the analyzer asks for.
@Suite("Live preview converter")
struct LivePreviewConverterTests {
  private func audio(frames: Int) -> PreviewAudio {
    PreviewAudio(samples: (0..<frames).map { Float(sin(Double($0) * 0.05)) * 0.5 }, sampleRate: 16_000)
  }

  private func format(_ common: AVAudioCommonFormat, rate: Double) throws -> AVAudioFormat {
    try #require(AVAudioFormat(commonFormat: common, sampleRate: rate, channels: 1, interleaved: false))
  }

  @Test("the tap's own format passes through untouched")
  func sameFormat() throws {
    let converter = LivePreviewConverter(target: try format(.pcmFormatFloat32, rate: 16_000))
    let buffer = try #require(converter.convert(audio(frames: 1365)))
    #expect(buffer.frameLength == 1365)
    #expect(buffer.format.commonFormat == .pcmFormatFloat32)
  }

  @Test("16 kHz floats become 16-bit samples with the same length")
  func toInt16() throws {
    let converter = LivePreviewConverter(target: try format(.pcmFormatInt16, rate: 16_000))
    let buffer = try #require(converter.convert(audio(frames: 1365)))
    #expect(buffer.format.commonFormat == .pcmFormatInt16)
    #expect(abs(Int(buffer.frameLength) - 1365) <= 32)
    let first = try #require(buffer.int16ChannelData).pointee
    #expect((0..<Int(buffer.frameLength)).contains { first[$0] != 0 }, "the signal survived the conversion")
  }

  @Test("a different sample rate is resampled by the rate's ratio")
  func resamples() throws {
    let converter = LivePreviewConverter(target: try format(.pcmFormatInt16, rate: 8_000))
    let buffer = try #require(converter.convert(audio(frames: 1600)))
    #expect(abs(Int(buffer.frameLength) - 800) <= 40)
  }

  @Test("empty audio is skipped")
  func emptyAudio() throws {
    let converter = LivePreviewConverter(target: try format(.pcmFormatFloat32, rate: 16_000))
    #expect(converter.convert(PreviewAudio(samples: [], sampleRate: 16_000)) == nil)
  }
}
