import IrisCore

/// Mac composition root: the same fake client as the iOS app until the real one lands.
struct MacCompositionRoot {
  let api: FakeAPIClient
  let history: HistoryModel

  init() {
    let api = FakeAPIClient()
    self.api = api
    history = HistoryModel(client: api)
  }

  func start() async {
    await SampleData.seed(api)
    await history.load()
  }
}
