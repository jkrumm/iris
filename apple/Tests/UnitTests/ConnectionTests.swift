import Foundation
import IrisCore
import Security
import Testing

@testable import Iris

@MainActor
@Suite("Connection")
struct ConnectionTests {
  @Test("the form needs an http(s) URL with a host and a token; whitespace is trimmed")
  func parsing() {
    let ok = ConnectionCredentials(urlText: "  https://iris.example.com/ \n", token: " abc ")
    #expect(ok?.serverURL.absoluteString == "https://iris.example.com/" && ok?.token == "abc")
    #expect(ConnectionCredentials(urlText: "http://192.0.2.1:3000", token: "t") != nil)
    #expect(ConnectionCredentials(urlText: "iris.example.com", token: "t") == nil)
    #expect(ConnectionCredentials(urlText: "ftp://iris.example.com", token: "t") == nil)
    #expect(ConnectionCredentials(urlText: "https://", token: "t") == nil)
    #expect(ConnectionCredentials(urlText: "https://iris.example.com", token: "  ") == nil)
  }

  @Test("saving stores the connection and reports the change; a bad URL stores nothing")
  func saving() {
    let store = InMemoryCredentialStore()
    var changes = 0
    let model = ConnectionModel(store: store) { changes += 1 }
    #expect(!model.canSave)

    model.urlText = "not a url"
    model.tokenText = "t"
    model.save()
    #expect(model.failure == .invalid && store.load() == nil && changes == 0)

    model.urlText = " https://iris.example.com "
    model.save()
    #expect(model.failure == nil && changes == 1)
    #expect(store.load()?.serverURL.absoluteString == "https://iris.example.com")
    #expect(model.urlText == "https://iris.example.com")
  }

  @Test("the form starts from what is saved")
  func seeded() throws {
    let saved = try #require(ConnectionCredentials(urlText: "https://iris.example.com", token: "secret"))
    let model = ConnectionModel(store: InMemoryCredentialStore(saved)) {}
    #expect(model.urlText == "https://iris.example.com" && model.tokenText == "secret" && model.canSave)
  }

  @Test("the Keychain keeps the token and the defaults the URL, and clear removes both")
  func keychainRoundTrip() throws {
    let store = KeychainCredentialStore(service: "com.jkrumm.iris.tests.\(UUID().uuidString)")
    defer { store.clear() }
    #expect(store.load() == nil)
    let first = try #require(ConnectionCredentials(urlText: "https://iris.example.com", token: "one"))
    do {
      try store.save(first)
    } catch let error as KeychainError where error.status == errSecMissingEntitlement {
      // The unsigned simulator build (CODE_SIGNING_ALLOWED=NO) carries no entitlements; only a signed build has a Keychain.
      try Test.cancel("Keychain unavailable in an unsigned build (errSecMissingEntitlement)")
    }
    #expect(store.load() == first)
    let second = try #require(ConnectionCredentials(urlText: "https://other.example.com", token: "two"))
    try store.save(second)
    #expect(store.load() == second)
    store.clear()
    #expect(store.load() == nil)
  }

  @Test("the shared client has no connection until one is saved, then follows it")
  func reconfigurable() async throws {
    let fake = FakeAPIClient()
    let client = ReconfigurableAPIClient(credentials: nil) { _ in fake }
    await #expect(throws: APIError.unauthorized) { try await client.health() }
    var eventsError: (any Error)?
    do {
      for try await _ in client.events() {}
    } catch {
      eventsError = error
    }
    #expect(eventsError as? APIError == .unauthorized)

    client.reconfigure(ConnectionCredentials(urlText: "https://iris.example.com", token: "t"))
    #expect(try await client.health().status == .ok)
    #expect(await fake.calls == [.health])

    client.reconfigure(nil)
    await #expect(throws: APIError.unauthorized) { try await client.health() }
  }
}

@MainActor
@Suite("CompositionRoot")
struct CompositionRootTests {
  @Test("-IrisFakeCapture keeps the app on fakes: configured, no form, no Keychain")
  func fake() {
    let root = CompositionRoot(arguments: ["-IrisFakeCapture"], credentials: InMemoryCredentialStore())
    #expect(root.mode == .fake && root.isConfigured && !root.opensOnSettings)
    #expect(root.connectionForm == nil && root.fakeCapture != nil)
  }

  @Test("without it the app is production, and with nothing saved it opens on Settings and loads nothing")
  func unconfigured() async {
    let root = CompositionRoot(arguments: [], credentials: InMemoryCredentialStore())
    #expect(root.mode == .production && !root.isConfigured && root.opensOnSettings)
    #expect(root.connectionForm != nil && root.fakeCapture == nil)
    #expect(root.settings.connection == .notConfigured)
    await root.start()
    #expect(!root.history.hasLoaded && !root.history.loadFailed)
  }

  @Test("a saved connection starts configured; saving one later reconfigures and bumps the revision")
  func configured() throws {
    let saved = try #require(ConnectionCredentials(urlText: "https://iris.example.com", token: "t"))
    let root = CompositionRoot(arguments: [], credentials: InMemoryCredentialStore(saved))
    #expect(root.isConfigured && !root.opensOnSettings && root.connectionRevision == 0)

    let empty = CompositionRoot(arguments: [], credentials: InMemoryCredentialStore())
    let form = try #require(empty.connectionForm)
    form.urlText = "https://iris.example.com"
    form.tokenText = "t"
    form.save()
    #expect(empty.isConfigured && empty.connectionRevision == 1)
  }
}
