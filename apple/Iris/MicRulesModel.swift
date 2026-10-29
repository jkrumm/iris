import Foundation
import IrisCapture
import IrisUI
import Observation

/// Settings → Microphone: the rule of the audio route that is active right now ("car → built-in mic", R-CAP-4). A rule is
/// keyed by the route's fingerprint (its output ports) and applied by the capture session whenever a take starts on that
/// route; the rules live on the device (`RouteManager.rules()`). Other routes get their rule when they are the active one.
@Observable
final class MicRulesModel {
  private(set) var route: RouteSnapshot?
  private(set) var rules: [String: String] = [:]

  private let routes: any RouteManager

  init(routes: any RouteManager) {
    self.routes = routes
  }

  /// The route's name for people: its output ports ("AirPods Pro, Car"), "This iPhone" when none is named.
  var routeTitle: String {
    let names = route?.outputNames.filter { !$0.isEmpty } ?? []
    return names.isEmpty
      ? String(localized: "This route", comment: "Mic rule: a route without named outputs")
      : names.joined(separator: ", ")
  }

  /// The UID the active route's rule prefers, nil for "Automatic".
  var selection: String? {
    guard let fingerprint = route?.fingerprint else { return nil }
    return rules[fingerprint]
  }

  var choices: [MicRuleChoice] {
    let inputs = (route?.availableInputs ?? []).map { MicRuleChoice(id: $0.uid, title: $0.name) }
    return [MicRuleChoice(id: nil, title: String(localized: "Automatic", comment: "Mic rule: the system picks"))]
      + inputs
  }

  func load() async {
    route = await routes.currentRoute()
    rules = await routes.rules()
  }

  /// Sets (or, for `nil`, removes) the active route's rule.
  func pick(_ uid: String?) async {
    // The route may have changed since the screen last read it: the rule goes to the route that is active now.
    route = await routes.currentRoute()
    guard let fingerprint = route?.fingerprint else { return }
    await routes.setRule(fingerprint: fingerprint, preferredPortUID: uid)
    rules = await routes.rules()
  }
}
