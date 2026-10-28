import Foundation
import IrisCapture
import IrisCore
import Observation

/// The one place that decides which adapters the app runs on. Launch arguments are read here, once.
///
/// - `-IrisFakeCapture` (every UI test and `make run-sim`): the fake API client with sample data, silent media clips
///   and fake capture, no network and no Keychain.
/// - Otherwise: production. The server URL and device token come from the connection form in Settings (token in the
///   Keychain); every model holds one ``ReconfigurableAPIClient``, which follows the saved connection. With nothing
///   saved the app opens on Settings and loads nothing, so there is neither a crash nor a silent fake.
///
/// Capture is wired but not consumed yet; the Record screen (R1) takes it from here.
@MainActor
@Observable
final class CompositionRoot {
  enum Mode: Equatable {
    case fake
    case production
  }

  let mode: Mode
  /// Production with nothing saved at launch: the app opens on Settings.
  let opensOnSettings: Bool
  let fakeCapture: FakeCapture?
  let history: HistoryModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  /// The editable connection; nil when running on fakes.
  private(set) var connectionForm: ConnectionModel?
  /// Bumped when the saved connection changes; `IrisApp` restarts ``start()`` on it.
  private(set) var connectionRevision = 0

  private let api: any APIClient
  private let fakeAPI: FakeAPIClient?
  private let credentials: (any CredentialStore)?
  private let reconfigurable: ReconfigurableAPIClient?

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: any CredentialStore = KeychainCredentialStore()
  ) {
    let diagnostics = DiagnosticsModel(pasteboard: SystemPasteboard())
    self.diagnostics = diagnostics
    if FakeCapture.isRequested(arguments: arguments) {
      let fake = FakeAPIClient()
      mode = .fake
      opensOnSettings = false
      api = fake
      fakeAPI = fake
      self.credentials = nil
      reconfigurable = nil
      history = HistoryModel(client: fake)
      stats = StatsModel(client: fake)
      settings = SettingsModel(client: fake)
      fakeCapture = FakeCapture(directory: FileManager.default.temporaryDirectory.appending(path: "iris-fake-capture"))
    } else {
      let saved = credentials.load()
      let client = ReconfigurableAPIClient(credentials: saved)
      mode = .production
      opensOnSettings = saved == nil
      api = client
      fakeAPI = nil
      self.credentials = credentials
      reconfigurable = client
      history = HistoryModel(client: client)
      stats = StatsModel(client: client)
      settings = SettingsModel(client: client, credentials: credentials)
      fakeCapture = nil
      connectionForm = ConnectionModel(store: credentials) { [unowned self] in connectionChanged() }
    }
  }

  /// A server URL and token are saved (always true on fakes).
  var isConfigured: Bool { credentials?.load() != nil || mode == .fake }

  /// The model behind one open memo detail.
  func detailModel(for memo: Memo) -> MemoDetailModel {
    MemoDetailModel(memo: memo, client: api, media: mediaSource())
  }

  /// The model behind one open composer sheet.
  func composerModel(for request: ComposerRequest) -> ComposerModel {
    ComposerModel(request: request, client: api)
  }

  /// Fakes: seeds the sample memos. Then, when there is a connection: loads the list and follows the server's events
  /// until the app's task is cancelled. After a connection change Settings and Stats reload too.
  func start() async {
    if let fakeAPI { await SampleData.seed(fakeAPI) }
    guard isConfigured else { return }
    if connectionRevision > 0 {
      await settings.load()
      await stats.load()
    }
    await history.load()
    await history.observeEvents()
  }

  /// The media routes for the connection saved right now, so a detail opened after a change uses the new token.
  private func mediaSource() -> any MemoMediaSource {
    switch mode {
    case .fake: FakeMediaSource()
    case .production:
      credentials?.load().map { AuthenticatedMediaSource(baseURL: $0.serverURL, bearerToken: $0.token) }
        ?? UnavailableMediaSource()
    }
  }

  private func connectionChanged() {
    reconfigurable?.reconfigure(credentials?.load())
    connectionRevision += 1
  }
}
