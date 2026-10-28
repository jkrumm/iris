import Foundation
import IrisCore

/// Where a memo's audio comes from: a URL plus the headers the server wants with it. A file URL is played as is; any
/// other is downloaded by ``MediaDownloader`` to `cacheName` and played from the file.
nonisolated struct MediaRequest: Equatable, Sendable {
  let url: URL
  let headers: [String: String]
  /// The file name (with the extension AVFoundation sniffs the format from) the download is kept under.
  var cacheName: String?
  /// A downloaded file that never changes (a recording) is kept and reused; anything else is fetched again each load.
  var isReusable = false
}

/// The port behind the detail screen's player and the reply's speech: the recording (`GET /v1/memos/:id/audio`) and
/// the spoken reply (`GET /v1/memos/:id/speech`). `nil` means there is nothing to play for that memo.
nonisolated protocol MemoMediaSource: Sendable {
  func audio(for memo: Memo) -> MediaRequest?
  func speech(for memo: Memo) -> MediaRequest?
}

/// The server's media routes with the device token in the `Authorization` header (``MediaDownloader`` sends it; the
/// player only ever sees the downloaded file). The speech route answers 409 when the memo has no reply, so it is only
/// offered for one that has. The recording is immutable and kept; the speech is derived per call and fetched fresh.
nonisolated struct AuthenticatedMediaSource: MemoMediaSource {
  let baseURL: URL
  let bearerToken: String

  func audio(for memo: Memo) -> MediaRequest? {
    guard !memo.isTyped, memo.state != .receiving, !memo.isDeleted else { return nil }
    return request(memo, "audio", fileExtension: "m4a", isReusable: true)
  }

  func speech(for memo: Memo) -> MediaRequest? {
    guard memo.hasReply, !memo.isDeleted else { return nil }
    return request(memo, "speech", fileExtension: "mp3", isReusable: false)
  }

  private func request(_ memo: Memo, _ route: String, fileExtension: String, isReusable: Bool) -> MediaRequest {
    MediaRequest(
      url: baseURL.appending(path: "v1/memos/\(memo.id)/\(route)"),
      headers: ["Authorization": "Bearer \(bearerToken)"],
      cacheName: "\(memo.id).\(route).\(fileExtension)", isReusable: isReusable)
  }
}

/// Silent clips written to the temp directory, so the fake API client's memos play in the simulator (the player,
/// the scrubber and skip-back all work) without a server or an audio file in the bundle.
nonisolated struct FakeMediaSource: MemoMediaSource {
  let directory: URL

  init(directory: URL = FileManager.default.temporaryDirectory.appending(path: "iris-fake-media")) {
    self.directory = directory
  }

  func audio(for memo: Memo) -> MediaRequest? {
    guard !memo.isTyped, memo.state != .receiving else { return nil }
    return clip(named: "\(memo.id).audio", seconds: memo.audioSeconds ?? 10)
  }

  func speech(for memo: Memo) -> MediaRequest? {
    guard memo.hasReply else { return nil }
    return clip(named: "\(memo.id).speech", seconds: 4)
  }

  private func clip(named name: String, seconds: Double) -> MediaRequest? {
    let url = directory.appending(path: "\(name).wav")
    if !FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.silentWAV(seconds: seconds).write(to: url)
      } catch {
        return nil
      }
    }
    return MediaRequest(url: url, headers: [:])
  }

  /// 8 kHz, 8-bit, mono PCM: `seconds` of silence (the 0x80 midpoint).
  static func silentWAV(seconds: Double) -> Data {
    let rate = 8_000
    let samples = max(Int(seconds * Double(rate)), 1)
    func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    var bytes: [UInt8] = Array("RIFF".utf8) + le32(36 + samples) + Array("WAVEfmt ".utf8)
    bytes += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate) + le16(1) + le16(8)
    bytes += Array("data".utf8) + le32(samples)
    return Data(bytes) + Data(repeating: 0x80, count: samples)
  }
}

extension Memo {
  /// There is a reply to speak: the server's `/speech` is a 409 with neither the reply text nor a spoken summary.
  nonisolated var hasReply: Bool {
    replyText?.isEmpty == false || summary?.spoken.isEmpty == false
  }
}

/// Nothing to play: the media source while the app has no connection.
nonisolated struct UnavailableMediaSource: MemoMediaSource {
  func audio(for memo: Memo) -> MediaRequest? { nil }
  func speech(for memo: Memo) -> MediaRequest? { nil }
}
