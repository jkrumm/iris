/// The JSON error body (`error.json`). The `error` code is a closed vocabulary.
public struct ErrorBody: Codable, Hashable, Sendable {
  public var error: APIErrorCode
  public var message: String

  public init(error: APIErrorCode, message: String) {
    self.error = error
    self.message = message
  }
}

/// 422 from `complete`: the segment indices the server has not received.
public struct MissingSegmentsBody: Codable, Hashable, Sendable {
  public var error: APIErrorCode
  public var message: String
  public var missing: [Int]

  public init(message: String, missing: [Int]) {
    self.error = .missingSegments
    self.message = message
    self.missing = missing
  }
}

/// 413 from the segment upload.
public struct TooLargeBody: Codable, Hashable, Sendable {
  public var error: APIErrorCode
  public var message: String
  public var maxBytes: Int

  public init(message: String, maxBytes: Int) {
    self.error = .tooLarge
    self.message = message
    self.maxBytes = maxBytes
  }
}
