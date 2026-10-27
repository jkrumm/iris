import Foundation

/// Every failure `APIClient` methods throw. Cancellation is the one exception: it surfaces as
/// `CancellationError` so callers can treat it like any other cancelled task.
public enum APIError: Error, Hashable, Sendable {
  /// 401: the bearer token is missing or wrong. The body is plain text (`Unauthorized`), not JSON.
  case unauthorized
  /// A JSON error body (`error.json`) with its HTTP status.
  case server(status: Int, body: ErrorBody)
  /// 422 from `complete`: these segment indices are missing.
  case missingSegments(message: String, missing: [Int])
  /// 413 from the segment upload.
  case tooLarge(message: String, maxBytes: Int)
  /// A non-2xx response whose body is not a contract error body (a proxy page, for instance).
  case unexpectedStatus(Int)
  /// The response did not decode as its contract type.
  case decoding(String)
  /// The request never produced an HTTP response.
  case transport(URLError.Code)
  /// A test double has nothing scripted for this call.
  case notScripted(String)
}

extension APIError {
  /// Maps a non-2xx response to the most specific case.
  static func from(status: Int, body: Data) -> APIError {
    if status == 401 { return .unauthorized }
    let decoder = IrisJSON.makeDecoder()
    guard let error = try? decoder.decode(ErrorBody.self, from: body) else { return .unexpectedStatus(status) }
    switch error.error {
    case .missingSegments:
      if let detail = try? decoder.decode(MissingSegmentsBody.self, from: body) {
        return .missingSegments(message: detail.message, missing: detail.missing)
      }
    case .tooLarge:
      if let detail = try? decoder.decode(TooLargeBody.self, from: body) {
        return .tooLarge(message: detail.message, maxBytes: detail.maxBytes)
      }
    default:
      break
    }
    return .server(status: status, body: error)
  }
}
