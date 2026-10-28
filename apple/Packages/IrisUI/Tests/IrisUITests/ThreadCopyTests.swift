import Foundation
import Testing

@testable import IrisUI

struct ThreadCopyTests {
  /// The resources of one language, as a bundle of its own.
  private func bundle(_ language: String) throws -> Bundle {
    let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
    return try #require(Bundle(path: path))
  }

  @Test(
    "the turn count takes the catalog's plural form, in English and German",
    arguments: [
      ("en", 0, "0 turns"), ("en", 1, "1 turn"), ("en", 2, "2 turns"), ("en", 12, "12 turns"),
      ("de", 0, "0 Runden"), ("de", 1, "1 Runde"), ("de", 2, "2 Runden"), ("de", 12, "12 Runden"),
    ])
  func turnCount(language: String, count: Int, expected: String) throws {
    #expect(ThreadCopy.turnCount(count, in: try bundle(language)) == expected)
  }
}
