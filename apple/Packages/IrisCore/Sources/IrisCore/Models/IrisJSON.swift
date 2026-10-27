import Foundation

/// The one place that decides how Iris wire JSON maps to Swift: camelCase keys as on the wire, dates as
/// ISO 8601 with fractional seconds (`2026-03-14T09:20:41.512Z`).
public enum IrisJSON {
  private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let plainStyle = Date.ISO8601FormatStyle()

  /// A fresh decoder (`JSONDecoder` is not `Sendable`, so callers do not share one).
  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let string = try decoder.singleValueContainer().decode(String.self)
      if let date = try? fractionalStyle.parse(string) { return date }
      if let date = try? plainStyle.parse(string) { return date }
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(string)"))
    }
    return decoder
  }

  /// A fresh encoder with stable key order.
  public static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      // The formatter truncates to milliseconds; half a millisecond turns that into rounding, so a date
      // parsed from `.204` does not come back as `.203`.
      try container.encode(fractionalStyle.format(date.addingTimeInterval(0.0005)))
    }
    return encoder
  }
}
