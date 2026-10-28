import Foundation
import IrisCapture
import IrisCore

/// The one place that decides which adapters the app runs on. Launch arguments are read here, once.
/// Capture is wired but not consumed yet; the Record screen (R1) takes it from here.
struct CompositionRoot {
  let api: FakeAPIClient
  let fakeCapture: FakeCapture?
  let history: HistoryModel

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    let api = FakeAPIClient()
    self.api = api
    history = HistoryModel(client: api)
    fakeCapture =
      FakeCapture.isRequested(arguments: arguments)
      ? FakeCapture(directory: FileManager.default.temporaryDirectory.appending(path: "iris-fake-capture"))
      : nil
  }

  /// Seeds the sample memos, loads the list, then follows the server's events until the app's task is cancelled.
  func start() async {
    await SampleData.seed(api)
    await history.load()
    await history.observeEvents()
  }
}
