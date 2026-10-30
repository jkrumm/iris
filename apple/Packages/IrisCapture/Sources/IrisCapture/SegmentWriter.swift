import Foundation

/// The crash-safe PCM copy ("shadow") the recorder keeps next to a segment while it is open (docs/research/2026-10-30-avaudiofile-kill.md).
/// An AAC `.m4a` gets its index at close, so a kill leaves the audio on disk but unreadable; 16-bit PCM in a CAF has no index
/// and reads back whole. The shadow is deleted when the segment closes cleanly and transcoded by the startup sweep when it is not.
enum SegmentShadow {
  static let fileExtension = "caf"

  /// `<memo>-<index>.caf` beside the segment's `<memo>-<index>.m4a`.
  static func url(of segment: URL) -> URL { segment.deletingPathExtension().appendingPathExtension(fileExtension) }

  /// The segment a shadow stands for.
  static func segment(of shadow: URL) -> URL { shadow.deletingPathExtension().appendingPathExtension("m4a") }

  static func isShadow(_ name: String) -> Bool { name.hasSuffix(".\(fileExtension)") && Outbox.parse(name) != nil }
}

#if canImport(AVFAudio)
  import AVFAudio

  /// The two files of one open segment: the AAC `.m4a` the outbox uploads and its PCM shadow.
  ///
  /// A failing shadow never fails the take: the m4a is the segment, the shadow only exists for the day the app is killed.
  final class SegmentWriter {
    let url: URL
    private var aac: AVAudioFile?
    private var shadow: AVAudioFile?
    private let shadowURL: URL

    init(url: URL, sampleRate: Int) throws {
      self.url = url
      shadowURL = SegmentShadow.url(of: url)
      aac = try AVAudioFile(
        forWriting: url, settings: Self.aacSettings(sampleRate: sampleRate), commonFormat: .pcmFormatFloat32,
        interleaved: false)
      do {
        shadow = try AVAudioFile(
          forWriting: shadowURL, settings: Self.pcmSettings(sampleRate: sampleRate), commonFormat: .pcmFormatFloat32,
          interleaved: false)
      } catch {
        Log.capture.error("shadow file not opened: \(String(describing: error), privacy: .public)")
      }
    }

    static func aacSettings(sampleRate: Int) -> [String: Any] {
      [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Double(sampleRate),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
      ]
    }

    static func pcmSettings(sampleRate: Int) -> [String: Any] {
      [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Double(sampleRate),
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
    }

    /// Throws when the m4a write fails; a shadow write that fails drops the shadow and carries on.
    func write(_ buffer: AVAudioPCMBuffer) throws {
      guard let aac else { return }
      try aac.write(from: buffer)
      guard let shadow else { return }
      do {
        try shadow.write(from: buffer)
      } catch {
        Log.capture.error("shadow write failed, dropped: \(String(describing: error), privacy: .public)")
        self.shadow = nil
        try? FileManager.default.removeItem(at: shadowURL)
      }
    }

    /// Releases the files (which finalizes the m4a) and removes the shadow once the m4a reads back; a shadow whose m4a does not
    /// play stays for the next launch's sweep.
    func close() {
      aac = nil
      shadow = nil
      guard FileManager.default.fileExists(atPath: shadowURL.path) else { return }
      if Outbox.inspectAudioFile(url) != nil {
        try? FileManager.default.removeItem(at: shadowURL)
      } else {
        Log.capture.error(
          "segment \(self.url.lastPathComponent, privacy: .public) does not read back, its shadow is kept")
      }
    }

    // MARK: Recovery

    /// A shadow shorter than this holds only the file header (a kill right after it was opened).
    private static let headerBytes = 4096

    /// Transcodes a shadow to `<memo>-<index>.m4a` beside it, replacing the truncated m4a a kill left. The shadow is not touched.
    static func recover(shadow: URL, sampleRate: Int) -> ShadowRecovery {
      let target = SegmentShadow.segment(of: shadow)
      let scratch = FileManager.default.temporaryDirectory.appending(path: "recover-\(UUID().uuidString).m4a")
      defer { try? FileManager.default.removeItem(at: scratch) }
      let input: AVAudioFile
      do {
        input = try AVAudioFile(forReading: shadow)
      } catch {
        let size = (try? shadow.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size <= headerBytes { return .empty }
        Log.outbox.error(
          "shadow \(shadow.lastPathComponent, privacy: .public) unreadable: \(String(describing: error), privacy: .public)"
        )
        return .failed
      }
      guard input.length > 0 else { return .empty }
      do {
        let chunk: AVAudioFrameCount = 16_384
        // Scoped so the output is released (finalized) before it is read back.
        do {
          let output = try AVAudioFile(
            forWriting: scratch, settings: aacSettings(sampleRate: sampleRate), commonFormat: .pcmFormatFloat32,
            interleaved: false)
          guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            return .failed
          }
          while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
          }
        }
        guard Outbox.inspectAudioFile(scratch) != nil else { return .failed }
        if FileManager.default.fileExists(atPath: target.path) {
          _ = try FileManager.default.replaceItemAt(target, withItemAt: scratch)
        } else {
          try FileManager.default.moveItem(at: scratch, to: target)
        }
        return .recovered(target)
      } catch {
        Log.outbox.error(
          "shadow \(shadow.lastPathComponent, privacy: .public) not recovered: \(String(describing: error), privacy: .public)"
        )
        return .failed
      }
    }
  }
#endif
