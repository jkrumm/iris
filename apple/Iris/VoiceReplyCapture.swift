import Foundation
import IrisCapture
import IrisCore
import os

/// A take recorded through the capture session and handed to the outbox: the memo is created when the take starts, the
/// segments go up while it runs, `complete` follows the stop. Under `-IrisFakeCapture` the same code runs on fake audio;
/// `claim` runs first thing in `begin`, before any `await` (the app sets its capture flag and pauses playback there: the
/// microphone must never hear it) and `release` once the session has ended or never began; `onBegan` / `willEnd` let the
/// fake composition feed its silent microphone.
final class OutboxVoiceReplyCapture: VoiceReplyCapture {
  private let stack: CaptureStack
  private let service: OutboxService
  private let isRecorderAvailable: Bool
  private let requestPermission: @Sendable () async -> Bool
  private let claim: () -> Int
  private let release: (_ claim: Int) async -> Void
  private let onBegan: () -> Void
  private let willEnd: () async -> Void
  private var held = 0
  private(set) var requests: [VoiceReplyRequest] = []
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "capture")

  init(
    stack: CaptureStack, service: OutboxService, isAvailable: Bool = true,
    requestPermission: @escaping @Sendable () async -> Bool = { true }, claim: @escaping () -> Int = { 0 },
    release: @escaping (_ claim: Int) async -> Void = { _ in }, onBegan: @escaping () -> Void = {},
    willEnd: @escaping () async -> Void = {}
  ) {
    self.stack = stack
    self.service = service
    isRecorderAvailable = isAvailable
    self.requestPermission = requestPermission
    self.claim = claim
    self.release = release
    self.onBegan = onBegan
    self.willEnd = willEnd
  }

  var isAvailable: Bool { isRecorderAvailable }

  func begin(_ request: VoiceReplyRequest) async throws {
    DeviceLog.shared.commandSource = "thread"
    let mine = claim()
    held = mine
    do {
      requests.append(request)
      guard await requestPermission() else { throw CaptureError.sessionFailure("microphone access was denied") }
      let session = try await stack.session()
      try await session.start(
        TakeRequest(
          mode: request.mode.rawValue, threadID: request.threadId, holdToTalk: true,
          title: String(localized: "Voice reply", comment: "Outbox row of a recorded reply")))
    } catch {
      await release(mine)
      throw error
    }
    onBegan()
  }

  func end(cancelled: Bool) async throws -> VoiceReplyOutcome {
    let mine = held
    await willEnd()
    let session: CaptureSession
    do {
      session = try await stack.session()
    } catch {
      await release(mine)
      throw error
    }
    if cancelled {
      // The memo of a cancelled reply may already exist on the server (it is deleted there): History must not show it.
      let id = await session.cancel()
      await release(mine)
      if let id { await service.created.forget(id.wireID) }
      return .discarded
    }
    let result: TakeResult?
    do {
      result = try await session.stop()
    } catch CaptureError.recordingFailed(let reason) {
      await release(mine)
      logger.error("voice take lost, the recorder failed: \(reason, privacy: .public)")
      return .recordingFailed
    } catch {
      await release(mine)
      throw error
    }
    await release(mine)
    guard let result else { return .discarded }
    if let failure = result.failure {
      logger.error("voice take cut short, the recorder failed: \(failure, privacy: .public)")
    }
    switch await service.awaitCreated(result.memoID) {
    case .sent(let memo): return .sent(memo)
    case .queued, .refused, .stalled: return .queued
    }
  }
}
