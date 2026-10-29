import Foundation
import IrisCore
import IrisUI
import Observation
import os

/// Answers a parked memo with a route, or corrects the route of one that was already acted on (`POST /v1/memos/:id/route`).
/// The model's suggestion is preselected on a park; a herdr destination needs a tab from `GET /v1/herd`. The server's
/// refusals are words on the sheet: 400 when the destination is not available (the sheet stays open, another one can be
/// picked), 409 when somebody answered first (the memo is refreshed through `onRouted`'s sibling, `onStale`).
@MainActor
@Observable
final class RouteAnswerModel {
  enum Kind: Equatable {
    /// The memo is parked at `needs_route`: the answer routes it and the server drives it on.
    case answer
    /// The memo was acted on: the answer is only logged as a correction, nothing is re-sent.
    case correction
  }

  enum HerdState: Equatable {
    case idle
    case loading
    case loaded([HerdTab])
    case unavailable
  }

  let memo: Memo
  var destination: RouteDestination
  var tab: String?
  private(set) var herd = HerdState.idle
  private(set) var failure: String?
  private(set) var isSubmitting = false
  /// The server accepted the answer; the sheet closes on it.
  private(set) var routed: Memo?

  private let client: any APIClient
  private let onStale: () -> Void
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "route")
  /// Bumped by every herd load; an answer that finds it changed belongs to a load that was superseded or cancelled.
  private var herdLoads = 0

  init(memo: Memo, client: any APIClient, onStale: @escaping () -> Void = {}) {
    self.memo = memo
    self.client = client
    self.onStale = onStale
    destination = Self.preselection(for: memo)
  }

  /// A memo the user can still send a route for: parked, or acted on and not deleted.
  static func canRoute(_ memo: Memo) -> Bool {
    guard !memo.isDeleted else { return false }
    switch memo.state {
    case .needsRoute: return true
    case .acted, .summarized, .notified: return memo.route != nil
    default: return false
    }
  }

  /// The suggestion of a low-confidence park, else the route a correction starts from, else Hermes.
  private static func preselection(for memo: Memo) -> RouteDestination {
    let named = memo.state == .needsRoute ? memo.routeSuggestion : memo.route
    return named.flatMap(RouteDestination.init(spoken:)) ?? .hermes
  }

  var kind: Kind { memo.state == .needsRoute ? .answer : .correction }

  var suggestion: RouteDestination? { memo.routeSuggestion.flatMap(RouteDestination.init(spoken:)) }

  /// Why the memo parked; only a park carries one.
  var reason: String? { kind == .answer ? memo.routeReason : nil }

  var tabs: RouteAnswerTabs {
    guard destination == .herdr else { return .notNeeded }
    switch herd {
    case .idle, .loading: return .loading
    case .unavailable:
      return .unavailable(
        String(localized: "herdr is not reachable, so a tab cannot be picked.", comment: "Route sheet: herd failed"))
    case .loaded(let tabs):
      guard !tabs.isEmpty else {
        return .unavailable(
          String(localized: "herdr has no live tab to send this to.", comment: "Route sheet: no tab"))
      }
      return .loaded(tabs.map(Self.choice))
    }
  }

  var canSubmit: Bool {
    guard !isSubmitting, routed == nil else { return false }
    return destination != .herdr || tab != nil
  }

  /// Reads the herd the first time herdr is the destination. A failure is shown, and herdr cannot be sent until it loads.
  func loadHerd() async {
    guard destination == .herdr else { return }
    if case .loaded = herd { return }
    herdLoads += 1
    let load = herdLoads
    herd = .loading
    do {
      let tabs = try await client.herd().tabs
      guard load == herdLoads else { return }
      herd = .loaded(tabs)
      if tab == nil || !tabs.contains(where: { $0.id == tab }) { tab = tabs.count == 1 ? tabs.first?.id : nil }
    } catch is CancellationError {
      // Cancelled by switching destination: the next time herdr is chosen, the load starts over.
      if load == herdLoads { herd = .idle }
    } catch {
      guard load == herdLoads else { return }
      logger.error("herd load failed: \(String(describing: error), privacy: .public)")
      herd = .unavailable
      tab = nil
    }
  }

  /// Sends the route. Returns the memo the server answered with (also kept in ``routed``); nil when it refused or failed
  /// (``failure`` says why).
  @discardableResult
  func submit() async -> Memo? {
    guard canSubmit else { return nil }
    isSubmitting = true
    failure = nil
    defer { isSubmitting = false }
    do {
      let request = RouteRequest(destination: destination, tab: destination == .herdr ? tab : nil)
      let memo = try await client.routeMemo(id: memo.id, request: request)
      routed = memo
      return memo
    } catch is CancellationError {
      return nil
    } catch {
      failure = message(for: error)
      if case APIError.server(409, _) = error { onStale() }
      return nil
    }
  }

  private func message(for error: any Error) -> String {
    guard case APIError.server(let status, let body) = error else {
      logger.error("route failed: \(String(describing: error), privacy: .public)")
      return String(localized: "Could not reach the server. Try again.", comment: "Route sheet: transport failure")
    }
    switch status {
    case 400 where body.message.contains("not available"):
      return String(
        localized: "\(destination.title) is not available on the server right now. Pick another destination.",
        comment: "Route sheet: the destination is not registered")
    case 404:
      return String(localized: "This memo no longer exists.", comment: "Route sheet: unknown memo")
    case 409:
      return String(
        localized: "This memo was already routed. It has been refreshed.",
        comment: "Route sheet: somebody answered first")
    default:
      return body.message
    }
  }

  private static func choice(_ tab: HerdTab) -> RouteAnswerTab {
    RouteAnswerTab(
      id: tab.id, title: tab.label,
      subtitle: [tab.repo, tab.agentState.label].filter { !$0.isEmpty }.joined(separator: " · "))
  }
}

extension RouteDestination {
  /// A destination as the server names one (`route`, `routeSuggestion`): a herdr tab is `herdr` or, in a mode, `tab`.
  init?(spoken name: String) {
    switch name {
    case "tab": self = .herdr
    default: self.init(rawValue: name)
    }
  }

  var systemImage: String? { self == .herdr ? "terminal" : nil }
}

extension AgentState {
  var label: String {
    switch self {
    case .idle: String(localized: "idle", comment: "Agent state of a herdr tab")
    case .working: String(localized: "working", comment: "Agent state of a herdr tab")
    case .blocked: String(localized: "blocked", comment: "Agent state of a herdr tab")
    case .done: String(localized: "done", comment: "Agent state of a herdr tab")
    case .unknown: ""
    }
  }
}
