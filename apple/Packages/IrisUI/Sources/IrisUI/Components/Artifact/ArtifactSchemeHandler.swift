import Foundation
import WebKit

/// Serves an island's content from memory and the IrisUI bundle under `iris-artifact://`, so nothing loads over the network and
/// the page works offline. `iris-artifact://app/<file>` is a bundled file, `iris-artifact://doc/page` the island's own HTML string.
struct ArtifactSchemeHandler: URLSchemeHandler {
  static let scheme = "iris-artifact"
  static let bundledHost = "app"
  static let documentHost = "doc"
  static let documentPath = "/page"

  /// Bundled pages may run scripts and styles from the island's own origin, never connect anywhere (`connect-src` falls back to `'none'`).
  static let bundledPolicy =
    "default-src 'none'; script-src iris-artifact:; style-src iris-artifact:; img-src iris-artifact: data:; "
    + "font-src iris-artifact:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  /// Generated documents get inline styles and data images, no script at all.
  static let documentPolicy =
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'; "
    + "frame-ancestors 'none'"

  /// The island's own HTML, served at `iris-artifact://doc/page`.
  let document: String?

  static func url(for entry: ArtifactEntry) -> URL? {
    switch entry {
    case .bundled(let file): URL(string: "\(scheme)://\(bundledHost)/\(file)")
    case .html: URL(string: "\(scheme)://\(documentHost)\(documentPath)")
    }
  }

  func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
    let answer = Self.answer(for: request.url, document: document)
    return AsyncThrowingStream { continuation in
      if let response = HTTPURLResponse(
        url: request.url ?? URL(fileURLWithPath: "/"), statusCode: answer.status, httpVersion: "HTTP/1.1",
        headerFields: answer.headers)
      {
        continuation.yield(.response(response))
        continuation.yield(.data(answer.body))
      }
      continuation.finish()
    }
  }

  struct Answer: Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data
  }

  static func answer(for url: URL?, document: String?) -> Answer {
    guard let url, url.scheme?.lowercased() == scheme else { return notFound(policy: bundledPolicy) }
    switch url.host?.lowercased() {
    case documentHost:
      guard url.path == documentPath, let document else { return notFound(policy: documentPolicy) }
      return Answer(
        status: 200, headers: headers(type: "text/html; charset=utf-8", policy: documentPolicy),
        body: Data(document.utf8))
    case bundledHost:
      let name = String(url.path.dropFirst())
      guard isFlatFileName(name), let (data, type) = bundledFile(named: name) else {
        return notFound(policy: bundledPolicy)
      }
      return Answer(status: 200, headers: headers(type: type, policy: bundledPolicy), body: data)
    default:
      return notFound(policy: bundledPolicy)
    }
  }

  /// Only flat names: no separators, no `..` as a whole name, nothing that could leave the resource folder.
  static func isFlatFileName(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != ".." else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
  }

  static func contentType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "js": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    default: "application/octet-stream"
    }
  }

  private static func bundledFile(named name: String) -> (Data, String)? {
    let file = URL(fileURLWithPath: name)
    let (base, ext) = (file.deletingPathExtension().lastPathComponent, file.pathExtension)
    let bundle = #bundle
    guard
      let url = bundle.url(forResource: base, withExtension: ext)
        ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Artifact"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return (data, contentType(forExtension: ext))
  }

  private static func headers(type: String, policy: String) -> [String: String] {
    [
      "Content-Type": type,
      "Content-Security-Policy": policy,
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-store",
    ]
  }

  private static func notFound(policy: String) -> Answer {
    Answer(
      status: 404, headers: headers(type: "text/plain; charset=utf-8", policy: policy), body: Data("Not found".utf8))
  }
}
