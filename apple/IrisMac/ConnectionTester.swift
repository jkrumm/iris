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
    /// The probe against the values that were just saved passed.
    case savedConnected
    case rejected
    /// The request never got an answer (network, Tailscale, a gateway in front of a server that is down).
    case unreachable
    /// The server answered, but not with what a healthy Iris server says.
    case serverError
    /// The typed values are not a usable address and token.
    case invalid
  }

  private(set) var outcome: Outcome?
  private let makeClient: @Sendable (ConnectionCredentials) -> any APIClient
  /// The values the shown outcome is about: a field edit that normalizes to the same pair (Save trims whitespace) keeps it.
  private var probed: ConnectionCredentials?
  private var probing: Task<Void, Never>?

  init(makeClient: @escaping @Sendable (ConnectionCredentials) -> any APIClient) {
    self.makeClient = makeClient
  }

  /// Forgets the last result and abandons a probe in flight: the fields changed, so it no longer describes them.
  func reset() {
    probing?.cancel()
    probing = nil
    probed = nil
    outcome = nil
  }

  /// Called when a field is edited: resets unless the fields still mean the pair the outcome is about.
  func fieldsChanged(urlText: String, tokenText: String) {
    if case .success(let credentials) = ConnectionCredentials.validate(urlText: urlText, token: tokenText),
      credentials == probed
    {
      return
    }
    reset()
  }

  /// Starts a probe of the typed values. `saved` marks one run right after Save, whose success reads "Saved — connected".
  func test(urlText: String, tokenText: String, saved: Bool = false) {
    probing?.cancel()
    probing = nil
    guard case .success(let credentials) = ConnectionCredentials.validate(urlText: urlText, token: tokenText) else {
      probed = nil
      outcome = .invalid
      return
    }
    probed = credentials
    outcome = .testing
    let client = makeClient(credentials)
    probing = Task {
      guard let result = await Self.probe(client), !Task.isCancelled else { return }
      outcome = result == .connected && saved ? .savedConnected : result
    }
  }

  /// Returns once the probe in flight has finished or been abandoned.
  func settled() async {
    await probing?.value
  }

  /// nil: cancelled, nothing to say.
  private static func probe(_ client: any APIClient) async -> Outcome? {
    do {
      _ = try await client.health()
      _ = try await client.whoami()
      return .connected
    } catch is CancellationError {
      return nil
    } catch let error as APIError {
      return outcome(for: error)
    } catch {
      return .unreachable
    }
  }

  private static func outcome(for error: APIError) -> Outcome {
    switch error {
    case .unauthorized: .rejected
    case .transport, .unexpectedStatus(502...504): .unreachable
    default: .serverError
    }
  }
}
