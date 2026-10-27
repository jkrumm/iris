import Foundation
import Testing

@testable import IrisCore

/// The repo's `contracts/` directory, located from this file's path (no bundled resources).
enum Contracts {
  enum LocationError: Error { case repoRootNotFound(from: String) }

  static func root(from file: String = #filePath) throws -> URL {
    var directory = URL(filePath: file).deletingLastPathComponent()
    while directory.path != "/" {
      let contracts = directory.appending(path: "contracts")
      if FileManager.default.fileExists(atPath: contracts.appending(path: "manifest.json").path) {
        return contracts
      }
      directory.deleteLastPathComponent()
    }
    throw LocationError.repoRootNotFound(from: file)
  }

  /// Schema names: the file names in `contracts/schema` without `.json`.
  static func schemaNames() throws -> Set<String> {
    let files = try FileManager.default.contentsOfDirectory(atPath: root().appending(path: "schema").path)
    return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
  }

  static func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: root().appending(path: "fixtures").appending(path: "\(name).json"))
  }

  static func manifest() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root().appending(path: "manifest.json")))
  }

  /// The `/v1/events` route object of the manifest.
  static func eventsRoute(in manifest: JSONValue) -> JSONValue? {
    guard case .object(let object) = manifest, case .array(let routes)? = object["routes"] else { return nil }
    return routes.first { route in
      guard case .object(let fields) = route, case .string(let path)? = fields["path"] else { return false }
      return path == "/v1/events"
    }
  }

  /// Every file in `contracts/fixtures`; empty only if the directory cannot be read (a separate test fails then).
  static func fixtures() -> [Fixture] {
    guard let names = try? schemaNames(), let directory = try? root().appending(path: "fixtures"),
      let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return files.filter { $0.hasSuffix(".json") }.sorted().map { file in
      let stem = String(file.dropLast(".json".count))
      // `<schema>.json` or `<schema>.<variant>.json`; schema names contain dots, so the longest match wins.
      let schema = names.filter { stem == $0 || stem.hasPrefix($0 + ".") }.max { $0.count < $1.count }
      return Fixture(fileName: file, schema: schema, path: directory.appending(path: file).path)
    }
  }
}

extension JSONValue {
  /// Every string stored under `key` anywhere in the document.
  func strings(forKey key: String) -> [String] {
    switch self {
    case .object(let object):
      object.flatMap { entry -> [String] in
        if entry.key == key, case .string(let value) = entry.value { return [value] }
        return entry.value.strings(forKey: key)
      }
    case .array(let values):
      values.flatMap { $0.strings(forKey: key) }
    default:
      []
    }
  }
}

struct Fixture: Sendable, CustomTestStringConvertible {
  let fileName: String
  let schema: String?
  let path: String

  var testDescription: String { fileName }
  var data: Data {
    get throws { try Data(contentsOf: URL(filePath: path)) }
  }
}
