import Foundation
import IrisCapture
import IrisUI
import Observation
import OSLog

/// Settings → Microphone: the rule of the audio route that is active right now ("car → built-in mic", R-CAP-4). A rule is
/// keyed by the route's fingerprint (its output ports) and applied by the capture session whenever a take starts on that
/// route; the rules live on the device (`RouteManager.rules()`). Other routes get their rule when they are the active one.
@Observable
final class MicRulesModel {
  private(set) var route: RouteSnapshot?
  private(set) var rules: [String: String] = [:]

  private let routes: any RouteManager
  /// Bumped by every `load()` and `pick()`; a read that finds it changed belongs to a call that was overtaken, so a late
  /// `load()` never writes an older route or rule set over a newer one.
  private var generation = 0
  /// Bumped by every `pick()` only: a pick that finds it changed before it writes was overtaken by a newer choice and is
  /// dropped. A `load()` does not count, it must never discard the user's choice.
  private var pickSequence = 0
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "mic-rules")

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
    generation += 1
    let mine = generation
    let current = await routes.currentRoute()
    let stored = await routes.rules()
    guard mine == generation else { return }
    route = current
    rules = stored
  }

  /// Sets (or, for `nil`, removes) the rule of the route the screen shows. `uid` was chosen from that route's inputs, so when
  /// the active route is another one by now nothing is saved: the screen refreshes to the new route and the choice is made again.
  func pick(_ uid: String?) async {
    guard let shown = route?.fingerprint else {
      logger.notice("mic rule not saved: no route is shown")
      return
    }
    generation += 1
    let mine = generation
    pickSequence += 1
    let myPick = pickSequence
    let current = await routes.currentRoute()
    guard current.fingerprint == shown else {
      logger.notice("mic rule not saved: the route changed since the choices were shown")
      let stored = await routes.rules()
      guard mine == generation else { return }
      route = current
      rules = stored
      return
    }
    // A newer pick started while the route was being read: its choice wins, this one is dropped unsaved.
    guard myPick == pickSequence else { return }
    await routes.setRule(fingerprint: shown, preferredPortUID: uid)
    let stored = await routes.rules()
    guard mine == generation else { return }
    route = current
    rules = stored
  }
}
