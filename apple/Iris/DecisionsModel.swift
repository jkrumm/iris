import Foundation
import IrisCore
import Observation
import os

/// The Decisions tab's data: the factory's open asks and health line (`GET /v1/factory`), and the answers sent back
/// (`POST /v1/factory/answer`). The tab polls lightly while it is visible; the badge reads ``openCount``.
@Observable
final class DecisionsModel {
  /// Why the last load left the screen without fresh data.
  enum LoadProblem: Equatable {
    /// 503 or no connection: the factory (or the server's way to it) is not there.
    case unreachable
    case failed
  }

  /// Where one card's answer stands. A card without an entry is idle.
  enum AnswerState: Equatable {
    case sending
    case failed(AnswerFailure)
  }

  enum AnswerFailure: Equatable {
    /// Offline or 503: sending again is the fix, with the same call id.
    case unreachable
    /// 409: the question is no longer open.
    case closed
    case other
  }

  /// A one-line message above the list that is not about one card.
  enum Notice: Equatable {
    /// 404: another device (or the owner at the terminal) answered first.
    case alreadyAnswered
  }

  private(set) var board: FactoryBoard?
  private(set) var loadProblem: LoadProblem?
  private(set) var isLoading = false
  private(set) var answers: [String: AnswerState] = [:]
  private(set) var notice: Notice?
  /// The card a push tap asked for; the view scrolls to it and marks it.
  private(set) var highlightedAskID: String?

  private let client: any APIClient
  private let makeCallID: () -> String
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "decisions")
  /// One call id per card and text, kept until the answer succeeds: a retry is one event at the factory, another text is a new one.
  private var callIDs: [String: (text: String, id: String)] = [:]
  /// Bumped by every load; an answer that finds it changed belongs to a load that has been superseded.
  private var generation = 0

  init(client: any APIClient, makeCallID: @escaping () -> String = { UUID().uuidString }) {
    self.client = client
    self.makeCallID = makeCallID
  }

  var asks: [FactoryAsk] { board?.asks ?? [] }
  var health: [FactoryHealthItem] { board?.health ?? [] }

  /// What the tab's badge shows: asks that take an answer and are not stale.
  var openCount: Int { asks.filter { $0.answerable && !$0.stale }.count }

  /// Loads the board. A failure keeps what is on screen; ``loadProblem`` says why it is old.
  func load() async {
    generation += 1
    let current = generation
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let loaded = try await client.factory()
      guard current == generation else { return }
      board = loaded
      loadProblem = nil
      answers = answers.filter { entry in loaded.asks.contains { $0.id == entry.key } }
      callIDs = callIDs.filter { entry in loaded.asks.contains { $0.id == entry.key } }
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("factory load failed: \(String(describing: error), privacy: .public)")
      loadProblem = Self.isUnreachable(error) ? .unreachable : .failed
    }
  }

  /// Sends `text` as the answer to `askID`. Success removes the card and refreshes.
  func answer(askID: String, text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, answers[askID] != .sending else { return }
    let callID = callID(for: askID, text: trimmed)
    answers[askID] = .sending
    notice = nil
    do {
      _ = try await client.answerFactoryAsk(FactoryAnswerRequest(askId: askID, text: trimmed, callId: callID))
      answers[askID] = nil
      callIDs[askID] = nil
      if var current = board {
        current.asks.removeAll { $0.id == askID }
        current.counts.asks = current.asks.count
        board = current
      }
      await load()
    } catch is CancellationError {
      answers[askID] = nil
    } catch let APIError.server(status, body) where status == 404 && body.error == .notFound {
      answers[askID] = nil
      callIDs[askID] = nil
      notice = .alreadyAnswered
      await load()
    } catch let APIError.server(status, body) where status == 409 && body.error == .badState {
      answers[askID] = .failed(.closed)
      await load()
    } catch {
      logger.error("factory answer failed: \(String(describing: error), privacy: .public)")
      answers[askID] = .failed(Self.isUnreachable(error) ? .unreachable : .other)
    }
  }

  func dismissNotice() { notice = nil }

  /// A push tap: marks the card and loads fresh data so a card newer than the list is there.
  func focus(askID: String) async {
    highlightedAskID = askID
    await load()
  }

  func clearHighlight() { highlightedAskID = nil }

  private func callID(for askID: String, text: String) -> String {
    if let kept = callIDs[askID], kept.text == text { return kept.id }
    let id = makeCallID()
    callIDs[askID] = (text, id)
    return id
  }

  private static func isUnreachable(_ error: any Error) -> Bool {
    switch error {
    case APIError.transport: true
    case APIError.server(let status, _): status == 503
    case APIError.unexpectedStatus(let status): status == 502 || status == 503 || status == 504
    default: false
    }
  }
}

/// The factory fields of a notification's `userInfo`: `factory.askId` is the ask the push is about.
nonisolated enum FactoryPush {
  static func askID(userInfo: [AnyHashable: Any]) -> String? {
    guard let factory = userInfo["factory"] as? [String: Any], let id = factory["askId"] as? String, !id.isEmpty
    else { return nil }
    return id
  }
}
