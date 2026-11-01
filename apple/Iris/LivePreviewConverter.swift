import AVFAudio
import Foundation
import IrisCapture
import IrisTelemetry

/// Turns the tap's 16 kHz mono samples into buffers in the recognizer's format. The analyzer does not resample or convert
/// ("to keep `CMTime` values sample-accurate"), so every buffer has to arrive exactly as `bestAvailableAudioFormat` says.
/// Owned and used by one task, never shared.
nonisolated final class LivePreviewConverter {
  private let target: AVAudioFormat
  private var converter: AVAudioConverter?
  private var source: AVAudioFormat?
  /// The first conversion failure is recorded, later ones are not: one buffer in a row of them says as much as a thousand.
  private var reported = false

  init(target: AVAudioFormat) {
    self.target = target
  }

  /// `nil` for audio that cannot be converted (nothing to hear, a format the system will not convert): the preview skips it,
  /// and the first such failure is recorded.
  func convert(_ audio: PreviewAudio) -> AVAudioPCMBuffer? {
    guard !audio.samples.isEmpty, audio.sampleRate > 0 else { return nil }
    switch attempt(audio) {
    case .success(let buffer): return buffer
    case .failure(let failure):
      report(failure)
      return nil
    }
  }

  private struct Failure: Error {
    let stage: String
    var error: NSError?
  }

  private func attempt(_ audio: PreviewAudio) -> Result<AVAudioPCMBuffer, Failure> {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false),
      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
      let channel = input.floatChannelData
    else { return .failure(Failure(stage: "input")) }
    audio.samples.withUnsafeBufferPointer { samples in
      guard let start = samples.baseAddress else { return }
      channel[0].update(from: start, count: samples.count)
    }
    input.frameLength = AVAudioFrameCount(audio.samples.count)
    if format == target { return .success(input) }

    if source != format {
      guard let fresh = AVAudioConverter(from: format, to: target) else { return .failure(Failure(stage: "converter")) }
      // No priming frames: they shift the analyzer's timestamps.
      fresh.primeMethod = .none
      converter = fresh
      source = format
    }
    guard let converter else { return .failure(Failure(stage: "converter")) }
    let ratio = target.sampleRate / format.sampleRate
    let capacity = AVAudioFrameCount((Double(audio.samples.count) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      return .failure(Failure(stage: "output"))
    }
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
    guard status != .error, error == nil, output.frameLength > 0 else {
      return .failure(Failure(stage: "convert", error: error))
    }
    return .success(output)
  }

  /// Which stage failed, and the system's error domain and code when it gave one. Never the audio.
  private func report(_ failure: Failure) {
    guard !reported else { return }
    reported = true
    var attributes: [String: AttributeValue] = ["stage": .string(failure.stage)]
    if let error = failure.error {
      attributes["error.domain"] = .string(error.domain)
      attributes["error.code"] = .int(error.code)
    }
    DeviceLog.shared.event("preview.convert_failed", severity: .warn, attributes)
  }
}
