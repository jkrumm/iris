#if os(iOS)
  import AVFAudio
  import Foundation
  import Testing

  @testable import IrisCapture

  struct AVAudioSessionRouteManagerTests {
    @Test func theProductionManagerYieldsRouteChangesRightAfterConstruction() async {
      let center = NotificationCenter()
      let routes = AVAudioSessionRouteManager(
        defaults: UserDefaults(suiteName: "iris.tests.\(UUID().uuidString)") ?? .standard, notificationCenter: center)
      let first = Task { await routes.routeChanges.first { _ in true } }
      // The observer starts asynchronously: post until the stream has it.
      let poster = Task {
        while !Task.isCancelled {
          center.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [
              AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ])
          try? await Task.sleep(for: .milliseconds(20))
        }
      }
      let change = await first.value
      poster.cancel()
      #expect(change?.reason == .deviceAppeared)
    }
  }
#endif
