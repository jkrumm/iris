import AVFAudio
import Foundation
import IrisCapture

/// Turns the tap's 16 kHz mono samples into buffers in the recognizer's format. The analyzer does not resample or convert
/// ("to keep `CMTime` values sample-accurate"), so every buffer has to arrive exactly as `bestAvailableAudioFormat` says.
/// Owned and used by one task, never shared.
nonisolated final class LivePreviewConverter {
  private let target: AVAudioFormat
  private var converter: AVAudioConverter?
  private var source: AVAudioFormat?

  init(target: AVAudioFormat) {
    self.target = target
  }

  /// `nil` for audio that cannot be converted (nothing to hear, a format the system will not convert): the preview skips it.
  func convert(_ audio: PreviewAudio) -> AVAudioPCMBuffer? {
    guard !audio.samples.isEmpty, audio.sampleRate > 0 else { return nil }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false),
      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
      let channel = input.floatChannelData
    else { return nil }
    audio.samples.withUnsafeBufferPointer { samples in
      guard let start = samples.baseAddress else { return }
      channel[0].update(from: start, count: samples.count)
    }
    input.frameLength = AVAudioFrameCount(audio.samples.count)
    if format == target { return input }

    if source != format {
      guard let fresh = AVAudioConverter(from: format, to: target) else { return nil }
      // No priming frames: they shift the analyzer's timestamps.
      fresh.primeMethod = .none
      converter = fresh
      source = format
    }
    guard let converter else { return nil }
    let ratio = target.sampleRate / format.sampleRate
    let capacity = AVAudioFrameCount((Double(audio.samples.count) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    nonisolated(unsafe) var supplied = false  // read and written only inside this synchronous convert call
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }
    guard status != .error, error == nil, output.frameLength > 0 else { return nil }
    return output
  }
}
