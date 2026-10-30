import IrisCapture
import Testing

@testable import Iris

@MainActor
@Suite("MicRulesModel")
struct MicRulesModelTests {
  private func makeModel(outputs: [String] = ["car"], names: [String] = ["Car"]) async -> (
    MicRulesModel, FakeRouteManager
  ) {
    let routes = FakeRouteManager(outputUIDs: outputs, outputNames: names)
    let model = MicRulesModel(routes: routes)
    await model.load()
    return (model, routes)
  }

  @Test("the choices are Automatic and every input of the active route")
  func choices() async {
    let (model, _) = await makeModel()
    #expect(model.choices.map(\.id) == [nil, FakeRouteManager.builtInMic.uid, FakeRouteManager.headsetMic.uid])
    #expect(model.choices.first?.title == "Automatic")
    #expect(model.routeTitle == "Car")
    #expect(model.selection == nil)
  }

  @Test("picking an input stores the rule for the route's fingerprint, and Automatic removes it")
  func pickAndClear() async {
    let (model, routes) = await makeModel(outputs: ["car", "speaker"], names: ["Car", "Speaker"])
    await model.pick(FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules() == ["car+speaker": FakeRouteManager.builtInMic.uid])
    #expect(model.selection == FakeRouteManager.builtInMic.uid)
    #expect(model.routeTitle == "Car, Speaker")

    await model.pick(nil)
    #expect(await routes.rules()["car+speaker"] == nil)
    #expect(model.selection == nil)
  }

  @Test("a choice made on a route that is gone is not saved: the screen refreshes to the active route")
  func staleRoute() async {
    let (model, routes) = await makeModel(outputs: ["car"], names: ["Car"])
    await routes.setAvailable(
      inputs: [FakeRouteManager.builtInMic], outputUIDs: ["speaker"], outputNames: ["Speaker"], reason: .deviceAppeared)
    await model.pick(FakeRouteManager.headsetMic.uid)
    #expect(await routes.rules().isEmpty)
    #expect(model.routeTitle == "Speaker")
    #expect(model.choices.map(\.id) == [nil, FakeRouteManager.builtInMic.uid])

    await model.pick(FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules() == ["speaker": FakeRouteManager.builtInMic.uid])
  }

  @Test("a pick before any route was read saves nothing")
  func pickWithoutARoute() async {
    let routes = FakeRouteManager()
    let model = MicRulesModel(routes: routes)
    await model.pick(FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules().isEmpty)
  }

  @Test("a load that finishes after a newer read does not overwrite it")
  func lateLoadIsDropped() async {
    let (model, routes) = await makeModel(outputs: ["car"], names: ["Car"])
    async let late: Void = model.load()
    await model.pick(FakeRouteManager.builtInMic.uid)
    await late
    #expect(model.selection == FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules() == ["car": FakeRouteManager.builtInMic.uid])
  }

  @Test("a route without named outputs still has a title")
  func unnamedRoute() async {
    let (model, _) = await makeModel(names: [])
    #expect(!model.routeTitle.isEmpty)
  }
}
