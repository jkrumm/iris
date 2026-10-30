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

  /// How far a shadow's length may differ from its m4a's before the m4a is not taken for a copy of it.
  static let durationTolerance: TimeInterval = 0.25

  /// Whether the file is a CAF that provably holds no audio: it has the `caff` magic and ends before its `data` chunk has a
  /// single audio byte (a take killed right after the file was opened). Anything else, a file that cannot be read, a header
  /// that does not parse or one that is only partly read, is not proof: `false`.
  static func provesNoAudio(fileAt url: URL) -> Bool {
    let window = 16_384
    guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: window) else {
      return false
    }
    defer { try? handle.close() }
    // A full window may be a prefix of a longer file: the header is not known to end where the buffer does.
    return provesNoAudio(head, isWholeFile: head.count < window)
  }

  static func provesNoAudio(_ data: Data, isWholeFile: Bool) -> Bool {
    let bytes = [UInt8](data)
    guard bytes.count >= 8, Array(bytes[0..<4]) == Array("caff".utf8) else { return false }
    var offset = 8
    while true {
      guard offset + 12 <= bytes.count else { return isWholeFile }  // ended inside the headers: no audio came after
      let type = Array(bytes[offset..<offset + 4])
      let size = bytes[offset + 4..<offset + 12].reduce(Int64(0)) { $0 << 8 | Int64($1) }
      let payload = offset + 12
      if type == Array("data".utf8) {
        let audioStart = payload + 4  // the edit count
        return isWholeFile && bytes.count <= audioStart
      }
      // A chunk larger than what is here ends outside the buffer: a cut header if this is the whole file, no proof otherwise.
      guard size >= 0, size <= Int64(bytes.count) else { return isWholeFile && size >= 0 }
      offset = payload + Int(size)
      if offset > bytes.count { return isWholeFile }  // a header chunk cut short
    }
  }
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

    /// The length of an audio file in seconds, `nil` when it does not open.
    static func duration(of url: URL) -> TimeInterval? {
      guard let file = try? AVAudioFile(forReading: url) else { return nil }
      return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: Recovery

    /// Transcodes a shadow to `<memo>-<index>.m4a` beside it, replacing the truncated m4a a kill left. The shadow is not touched.
    /// `.empty` only when a valid CAF proves it holds no audio; a file that cannot be read or parsed is `.failed` and is kept.
    static func recover(shadow: URL, sampleRate: Int) -> ShadowRecovery {
      let target = SegmentShadow.segment(of: shadow)
      let scratch = FileManager.default.temporaryDirectory.appending(path: "recover-\(UUID().uuidString).m4a")
      defer { try? FileManager.default.removeItem(at: scratch) }
      let input: AVAudioFile
      do {
        input = try AVAudioFile(forReading: shadow)
      } catch {
        if SegmentShadow.provesNoAudio(fileAt: shadow) { return .empty }
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
