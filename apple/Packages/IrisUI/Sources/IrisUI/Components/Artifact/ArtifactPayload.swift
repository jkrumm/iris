import Foundation
import SwiftUI

/// What an artifact's file becomes on screen: the page to load and, for the bundled renderer, the JSON its
/// `window.iris.render({artifact, theme})` receives (`web/src/payload.ts`).
///
/// A show spec and a markdown document render in the bundled page (`index.html`). An HTML document is served on its own as
/// the island's inline page (`ArtifactEntry.html`): the document CSP forbids every script and every load from outside, so it
/// gets no network and no bridge beyond the island's height and theme.
struct ArtifactContent: Equatable {
  static let rendererPage = "index.html"

  let entry: ArtifactEntry
  /// `nil` for an HTML document (it has no renderer to call).
  let payloadJSON: String?

  /// `nil` when the file cannot be what `asset` says it is (not JSON, not UTF-8): the caller shows the fence as code.
  init?(asset: ArtifactAsset, data: Data, scheme: ColorScheme) {
    let theme: [String: Any] = ["scheme": scheme == .dark ? "dark" : "light"]
    switch asset.kind {
    case .show:
      guard let spec = try? JSONSerialization.jsonObject(with: data), spec is [String: Any] else { return nil }
      guard let json = Self.json(["artifact": ["kind": "show", "spec": spec], "theme": theme]) else { return nil }
      entry = .bundled(Self.rendererPage)
      payloadJSON = json
    case .doc:
      guard let content = String(data: data, encoding: .utf8) else { return nil }
      if asset.format == .html {
        entry = .html(content)
        payloadJSON = nil
        return
      }
      var artifact: [String: Any] = ["kind": "doc", "format": "markdown", "content": content]
      if let title = asset.title { artifact["title"] = title }
      guard let json = Self.json(["artifact": artifact, "theme": theme]) else { return nil }
      entry = .bundled(Self.rendererPage)
      payloadJSON = json
    }
  }

  private static func json(_ object: [String: Any]) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

/// The artifact as a file to hand on (Share): the raw spec or document, named after its title.
enum ArtifactExport {
  static func fileName(for asset: ArtifactAsset) -> String {
    let title = asset.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let safe = String(
      title.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" ? $0 : "-" }
    ).trimmingCharacters(in: .whitespaces)
    let base = safe.isEmpty ? "artifact-\(asset.kind.rawValue)-\(asset.index + 1)" : String(safe.prefix(80))
    return "\(base).\(asset.fileExtension)"
  }

  /// Writes `data` to a fresh temporary file named for `asset` and returns its URL.
  static func file(for asset: ArtifactAsset, data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "iris-artifacts")
      .appending(path: asset.ref.assetID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: fileName(for: asset))
    try data.write(to: url, options: .atomic)
    return url
  }
}
