import Foundation

public enum TelemetryTransportError: Error, Equatable {
  case invalidResponse
  case rejected(statusCode: Int)
  /// The send did not finish in time (``RelayExporter``'s bound); the batch is kept and retried.
  case timedOut
}

/// Production transport: `POST {baseURL}/v1/telemetry` with the batch JSON and a bearer token.
public struct URLSessionTelemetryTransport: TelemetryTransport {
  private let baseURL: URL
  private let bearerToken: String
  private let session: URLSession

  public init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    self.session = session
  }

  public func send(_ batch: TelemetryBatch) async throws {
    var request = URLRequest(url: baseURL.appending(path: "v1/telemetry"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try batch.jsonData()
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TelemetryTransportError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw TelemetryTransportError.rejected(statusCode: http.statusCode)
    }
  }
}
