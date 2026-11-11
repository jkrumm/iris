import IrisCore
import IrisTelemetry
import Observation

/// Where a deep link, a notification tap or a Live Activity button wants the app to go. It holds one pending request until the
/// root can resolve it (a cold launch delivers the link before anything has loaded), and the input focus the opened
/// conversation still has to apply.
@MainActor
@Observable
final class ConversationRouter {
  struct Request: Equatable, Identifiable {
    let id: Int
    let link: ConversationLink
  }

  /// A conversation ready to push: the memo and the focus its screen applies once.
  struct Opened: Equatable {
    let memo: Memo
    let focus: ComposerFocus
  }

  /// The request waiting to be resolved.
  private(set) var pending: Request?
  /// The focus the screen of `memoID` still has to apply.
  private var routedFocus: (memoID: String, focus: ComposerFocus)?
  /// Bumped for every opened request, so a screen that is already showing the conversation can still apply a new focus.
  private(set) var focusRevision = 0
  private var counter = 0
  @ObservationIgnored private let log: (String, [String: AttributeValue]) -> Void

  init(log: @escaping (String, [String: AttributeValue]) -> Void = { DeviceLog.shared.event($0, $1) }) {
    self.log = log
  }

  func open(_ link: ConversationLink) {
    counter += 1
    pending = Request(id: counter, link: link)
  }

  /// The memo of `request`, from `local` (History's list) or else `fetch`. Takes the request off the router either way, so
  /// a memo that cannot be found is dropped (and logged) instead of retried forever. `nil` then.
  func resolve(
    _ request: Request, isConfigured: Bool, local: (String) -> Memo?, fetch: (String) async throws -> Memo
  ) async -> Opened? {
    guard pending == request else { return nil }
    guard isConfigured else { return drop(request, reason: "not_configured") }
    let memoID = request.link.memoID
    let memo: Memo
    if let known = local(memoID) {
      memo = known
    } else {
      do { memo = try await fetch(memoID) } catch { return drop(request, reason: "not_found") }
    }
    // A newer link arrived while the fetch ran: it wins.
    guard pending == request else { return nil }
    guard !memo.isDeleted else { return drop(request, reason: "deleted") }
    pending = nil
    routedFocus = (memo.id, request.link.focus)
    focusRevision += 1
    log("ui.route", ["memo": .string(memo.id), "focus": .string(request.link.focus.rawValue), "opened": true])
    return Opened(memo: memo, focus: request.link.focus)
  }

  /// Reply by voice: for a conversation opened with `.voice` focus, hands its thread to `start` (a take bound to it). A memo
  /// without a thread yet has nothing to bind to, so the conversation takes the keyboard focus instead. `resolve` returns
  /// each request once, so this runs once per request.
  func startVoiceReply(_ opened: Opened, start: (String) -> Void) {
    guard opened.focus == .voice else { return }
    guard let threadID = opened.memo.threadId else {
      routedFocus = (opened.memo.id, .keyboard)
      focusRevision += 1
      log("ui.route", ["memo": .string(opened.memo.id), "voice": false, "reason": "no_thread"])
      return
    }
    log("ui.route", ["memo": .string(opened.memo.id), "voice": true])
    start(threadID)
  }

  /// The focus for the screen showing any of `memoIDs`, once: a later visit to the same conversation starts without it.
  func takeFocus(forAnyOf memoIDs: Set<String>) -> ComposerFocus {
    guard let routed = routedFocus, memoIDs.contains(routed.memoID) else { return .none }
    routedFocus = nil
    return routed.focus
  }

  private func drop(_ request: Request, reason: String) -> Opened? {
    // A newer request may have replaced this one while it was resolving; it stays.
    if pending == request { pending = nil }
    log("ui.route", ["memo": .string(request.link.memoID), "opened": false, "reason": .string(reason)])
    return nil
  }
}
