import IrisCapture
import Testing

@testable import Iris

@MainActor
@Suite("MicRulesModel")
struct MicRulesModelTests {
  private func model(outputs: [String] = ["car"], names: [String] = ["Car"]) async -> (MicRulesModel, FakeRouteManager)
  {
    let routes = FakeRouteManager(outputUIDs: outputs, outputNames: names)
    let model = MicRulesModel(routes: routes)
    await model.load()
    return (model, routes)
  }

  @Test("the choices are Automatic and every input of the active route")
  func choices() async {
    let (model, _) = await model()
    #expect(model.choices.map(\.id) == [nil, FakeRouteManager.builtInMic.uid, FakeRouteManager.headsetMic.uid])
    #expect(model.choices.first?.title == "Automatic")
    #expect(model.routeTitle == "Car")
    #expect(model.selection == nil)
  }

  @Test("picking an input stores the rule for the route's fingerprint, and Automatic removes it")
  func pickAndClear() async {
    let (model, routes) = await model(outputs: ["car", "speaker"], names: ["Car", "Speaker"])
    await model.pick(FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules() == ["car+speaker": FakeRouteManager.builtInMic.uid])
    #expect(model.selection == FakeRouteManager.builtInMic.uid)
    #expect(model.routeTitle == "Car, Speaker")

    await model.pick(nil)
    #expect(await routes.rules()["car+speaker"] == nil)
    #expect(model.selection == nil)
  }

  @Test("a rule goes to the route that is active when it is picked, not the one the screen last read")
  func staleRoute() async {
    let (model, routes) = await model(outputs: ["car"], names: ["Car"])
    await routes.setAvailable(
      inputs: [FakeRouteManager.builtInMic], outputUIDs: ["speaker"], outputNames: ["Speaker"], reason: .deviceAppeared)
    await model.pick(FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules() == ["speaker": FakeRouteManager.builtInMic.uid])
    #expect(model.routeTitle == "Speaker")
  }

  @Test("a route without named outputs still has a title")
  func unnamedRoute() async {
    let (model, _) = await model(names: [])
    #expect(!model.routeTitle.isEmpty)
  }
}
