import IrisCapture
import IrisCore
import IrisUI
import SwiftUI

@main
struct IrisApp: App {
  @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
  @State private var root = CompositionRoot()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    IntentEvents.sink = DeviceLogIntentSink()
    DeviceLog.shared.start()
    if !FakeCapture.isRequested() { MetricKitRelay.shared.start() }
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let islands = ArtifactSpike.islands() {
          ArtifactIslandDemo(islands: islands)
        } else if let sample = ArtifactSample.requested() {
          ArtifactSampleScreen(sample: sample)
        } else {
          rootView
        }
      #else
        rootView
      #endif
    }
  }

  private var rootView: some View {
    RootView(
      history: root.history, isConfigured: root.isConfigured, take: root.take, stats: root.stats,
      settings: root.settings,
      diagnostics: root.diagnostics, micRules: root.micRules, spokenReplies: root.spokenReplies,
      connectionForm: root.connectionForm, startsOnSettings: root.opensOnSettings,
      makeDetail: root.detailModel(for:), makeComposer: root.composerModel(for:),
      makeThread: root.threadModel(for:), router: root.router, presence: root.presence,
      startReplyByVoice: { threadID in Task { await root.startReplyByVoice(threadID: threadID) } },
      fetchMemo: root.fetchMemo(id:)
    )
    .onOpenURL { url in
      guard let link = ConversationLink(url: url) else {
        DeviceLog.shared.event("ui.route", ["opened": false, "reason": "unknown_url"])
        return
      }
      root.router.open(link)
    }
    .task {
      pushDelegate.attach(router: root.router, presence: root.presence, play: { try await root.playReply(memoID: $0) })
    }
    .environment(\.replyImageStore, root.replyImages)
    .environment(\.artifactStore, root.artifacts)
    .task { DeviceLog.shared.sceneChanged(to: scenePhase.telemetryName) }
    .task(id: root.connectionRevision) { await root.start() }
    .task(id: root.connectionRevision) { await PushRegistrar.shared.connectionChanged() }
    .onChange(of: scenePhase) { _, phase in
      DeviceLog.shared.sceneChanged(to: phase.telemetryName)
      root.spokenReplies.isForeground = phase == .active
      if phase == .background { Task { await root.backgrounded() } }
      guard phase == .active else { return }
      Task { await root.foregrounded() }
      Task { await PushRegistrar.shared.foregrounded() }
    }
  }
}

extension ScenePhase {
  /// The name `app.lifecycle` and the ambient `app.state` carry.
  var telemetryName: String {
    switch self {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }
}
