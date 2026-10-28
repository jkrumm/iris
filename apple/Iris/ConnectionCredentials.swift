import Foundation
import Security

/// Where the app talks to: the server's base URL and this device's bearer token.
nonisolated struct ConnectionCredentials: Equatable, Sendable {
  let serverURL: URL
  let token: String

  /// Parses what the connection form holds. The URL must be http(s) with a host; surrounding whitespace is dropped.
  init?(urlText: String, token: String) {
    let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host()?.isEmpty == false
    else { return nil }
    self.serverURL = url
    self.token = token
  }
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

/// The token as a generic password item and the URL in `UserDefaults`. The item carries no explicit access group, so
/// it lands in the first `keychain-access-groups` entry, the App Group's, which the widgets and the notification
/// extension can read once they need it.
nonisolated struct KeychainCredentialStore: CredentialStore {
  let service: String
  private let urlKey: String

  init(service: String = "com.jkrumm.iris.device-token") {
    self.service = service
    urlKey = "\(service).server-url"
  }

  func load() -> ConnectionCredentials? {
    var query = tokenQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
      let token = String(data: data, encoding: .utf8), let url = UserDefaults.standard.string(forKey: urlKey)
    else { return nil }
    return ConnectionCredentials(urlText: url, token: token)
  }

  func save(_ credentials: ConnectionCredentials) throws {
    let data = Data(credentials.token.utf8)
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
    UserDefaults.standard.set(credentials.serverURL.absoluteString, forKey: urlKey)
  }

  func clear() {
    SecItemDelete(tokenQuery as CFDictionary)
    UserDefaults.standard.removeObject(forKey: urlKey)
  }

  private var tokenQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
  }
}
