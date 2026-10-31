import CryptoKit
import Foundation
import Security
import Synchronization

/// Where the app talks to: the server's base URL and this device's bearer token.
nonisolated struct ConnectionCredentials: Equatable, Sendable {
  let serverURL: URL
  let token: String

  enum Problem: Error, Equatable {
    /// Not a URL with a host, or no token.
    case invalid
    /// Plain http to a host other than this machine: the bearer token would travel in cleartext.
    case insecure
  }

  /// The address with the case-insensitive parts (scheme, host) lower-cased and a trailing slash dropped. The path is not
  /// normalized: it is case-sensitive, and `/Iris` and `/iris` are different servers behind one proxy.
  static func normalizedAddress(of url: URL) -> String {
    var normalized = url.absoluteString
    if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      parts.scheme = parts.scheme?.lowercased()
      parts.host = parts.host?.lowercased()
      normalized = parts.string ?? normalized
    }
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }

  /// A short digest of the server URL: tells servers apart (a Live Activity remembers which one its memo lives on) without
  /// keeping the address.
  var serverKey: String {
    let digest = SHA256.hash(data: Data(Self.normalizedAddress(of: serverURL).utf8))
    return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  private init(serverURL: URL, token: String) {
    self.serverURL = serverURL
    self.token = token
  }

  /// Parses what the connection form holds; nil when ``validate(urlText:token:)`` finds a problem.
  init?(urlText: String, token: String) {
    guard case .success(let credentials) = Self.validate(urlText: urlText, token: token) else { return nil }
    self = credentials
  }

  /// https with a host, or http only for this machine (the simulator's dev server); surrounding whitespace is dropped.
  static func validate(urlText: String, token: String) -> Result<ConnectionCredentials, Problem> {
    let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      let host = url.host()?.lowercased(), !host.isEmpty
    else { return .failure(.invalid) }
    switch scheme {
    case "https": return .success(ConnectionCredentials(serverURL: url, token: token))
    case "http" where Self.loopbackHosts.contains(host):
      return .success(ConnectionCredentials(serverURL: url, token: token))
    case "http": return .failure(.insecure)
    default: return .failure(.invalid)
    }
  }

  private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
}

/// Persistence for the connection. The token is a secret and lives in the Keychain; the URL is not.
nonisolated protocol CredentialStore: Sendable {
  func load() -> ConnectionCredentials?
  func save(_ credentials: ConnectionCredentials) throws
  func clear()
}

nonisolated struct KeychainError: Error, Equatable {
  let status: OSStatus
}

/// The two halves of a saved connection, stored apart: the token is a secret (Keychain), the URL is not (`UserDefaults`).
nonisolated protocol ConnectionStorage: Sendable {
  func readToken() -> String?
  func readURL() -> String?
  func write(token: String, url: String) throws
  func clear()
}

/// The token as a generic password item and the URL in `UserDefaults`. The item carries no explicit access group, so
/// it lands in the first `keychain-access-groups` entry, the App Group's, which the widgets and the notification
/// extension can read once they need it.
///
/// The two halves are written one after the other, so a reader in between would see the new token with the old URL, and
/// the telemetry relay would send the new server's token to the old server. Every read and write of the pair therefore
/// goes through one process-wide gate: a load sees the old pair or the new one, never a mix.
nonisolated struct KeychainCredentialStore: CredentialStore {
  private let storage: any ConnectionStorage

  private static let gate = Mutex(())

  init(service: String = "com.jkrumm.iris.device-token") {
    self.init(storage: KeychainDefaultsStorage(service: service))
  }

  init(storage: any ConnectionStorage) {
    self.storage = storage
  }

  func load() -> ConnectionCredentials? {
    let (token, url) = Self.gate.withLock { _ in (storage.readToken(), storage.readURL()) }
    guard let token, let url else { return nil }
    return ConnectionCredentials(urlText: url, token: token)
  }

  func save(_ credentials: ConnectionCredentials) throws {
    try Self.gate.withLock { _ in
      try storage.write(token: credentials.token, url: credentials.serverURL.absoluteString)
    }
  }

  func clear() {
    Self.gate.withLock { _ in storage.clear() }
  }
}

nonisolated struct KeychainDefaultsStorage: ConnectionStorage {
  let service: String
  private let urlKey: String

  init(service: String) {
    self.service = service
    urlKey = "\(service).server-url"
  }

  func readToken() -> String? {
    var query = tokenQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func readURL() -> String? { UserDefaults.standard.string(forKey: urlKey) }

  func write(token: String, url: String) throws {
    let data = Data(token.utf8)
    let update = SecItemUpdate(
      tokenQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecItemNotFound {
      var item = tokenQuery
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let add = SecItemAdd(item as CFDictionary, nil)
      guard add == errSecSuccess else { throw KeychainError(status: add) }
    } else if update != errSecSuccess {
      throw KeychainError(status: update)
    }
    UserDefaults.standard.set(url, forKey: urlKey)
  }

  func clear() {
    SecItemDelete(tokenQuery as CFDictionary)
    UserDefaults.standard.removeObject(forKey: urlKey)
  }

  private var tokenQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
  }
}
