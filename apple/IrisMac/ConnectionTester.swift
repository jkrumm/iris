import Foundation
import IrisCore
import Observation

/// Probes a server with the URL and token typed in Settings: `GET /health` (reachable) and `GET /v1/whoami` (the token is
/// accepted). Works on the typed values, so a connection can be checked before it is saved.
@MainActor
@Observable
final class ConnectionTester {
  enum Outcome: Equatable {
    case testing
    case connected
    /// Saved and the probe against what was saved passed.
    case savedConnected
    case rejected
    case unreachable
    /// The typed values are not a usable address and token.
    case invalid
  }

  private(set) var outcome: Outcome?
  private let makeClient: @Sendable (ConnectionCredentials) -> any APIClient
  private var generation = 0

  init(makeClient: @escaping @Sendable (ConnectionCredentials) -> any APIClient) {
    self.makeClient = makeClient
  }

  /// Forgets the last result: the fields changed, so it no longer describes them.
  func reset() {
    generation += 1
    outcome = nil
  }

  func test(urlText: String, tokenText: String, afterSave: Bool = false) async {
    generation += 1
    let current = generation
    guard case .success(let credentials) = ConnectionCredentials.validate(urlText: urlText, token: tokenText) else {
      outcome = .invalid
      return
    }
    outcome = .testing
    let result = await Self.probe(makeClient(credentials))
    guard current == generation else { return }
    outcome = result == .connected && afterSave ? .savedConnected : result
  }

  private static func probe(_ client: any APIClient) async -> Outcome {
    do {
      _ = try await client.health()
      _ = try await client.whoami()
      return .connected
    } catch APIError.unauthorized {
      return .rejected
    } catch {
      return .unreachable
    }
  }
}
