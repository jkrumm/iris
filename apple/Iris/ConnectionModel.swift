import Foundation
import Observation
import os

/// The editable server URL and device token behind Settings' connection section. Saving writes the credential store
/// and tells the composition, which points the shared client at the new server.
@Observable
final class ConnectionModel {
  var urlText: String
  var tokenText: String
  private(set) var failure: Failure?

  enum Failure: Equatable {
    case invalid
    case notStored
  }

  private let store: any CredentialStore
  private let onChange: @MainActor () -> Void
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "connection")

  init(store: any CredentialStore, onChange: @escaping @MainActor () -> Void) {
    self.store = store
    self.onChange = onChange
    let saved = store.load()
    urlText = saved?.serverURL.absoluteString ?? ""
    tokenText = saved?.token ?? ""
  }

  var canSave: Bool { !urlText.isEmpty && !tokenText.isEmpty }

  func save() {
    guard let credentials = ConnectionCredentials(urlText: urlText, token: tokenText) else {
      failure = .invalid
      return
    }
    do {
      try store.save(credentials)
    } catch {
      logger.error("credentials not stored: \(String(describing: error), privacy: .public)")
      failure = .notStored
      return
    }
    failure = nil
    urlText = credentials.serverURL.absoluteString
    tokenText = credentials.token
    onChange()
  }
}
