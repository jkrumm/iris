#if os(iOS)
  import AVFAudio
  import Foundation

  // Production adapters over AVAudioSession. Thin on purpose: all decisions live in the pure types.
  // Device-verified in spike S1/S2 (docs/spikes); they are only compile-checked in the package tests.

  public actor AVAudioSessionController: AudioSessionController {
    public nonisolated let interruptions: AsyncStream<InterruptionEvent>
    private let continuation: AsyncStream<InterruptionEvent>.Continuation
    private var observerTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    // Keeps the iOS 27 message observers registered; they are removed when the tokens deinit.
    private var observationTokens: [Any] = []
    private let events: any CaptureEvents

    public init(events: any CaptureEvents = NoCaptureEvents()) {
      self.events = events
      (interruptions, continuation) = AsyncStream.makeStream(of: InterruptionEvent.self)
    }

    public func configure() throws {
      let session = AVAudioSession.sharedInstance()
      do {
        // `.bluetoothHighQualityRecording` falls back to HFP; it is not available in the EU.
        try session.setCategory(
          .playAndRecord, mode: .default,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP, .bluetoothHighQualityRecording])
        try session.setPrefersNoInterruptionsFromSystemAlerts(true)
      } catch {
        events.sessionError(call: "setCategory", error: error)
        throw CaptureError.sessionFailure(String(describing: error))
      }
      observeInterruptions()
    }

    public func activate() throws {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        events.sessionError(call: "setActive", error: error)
        throw CaptureError.sessionFailure(String(describing: error))
      }
    }

    public func deactivate() throws {
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        events.sessionError(call: "setActive(false)", error: error)
        throw CaptureError.sessionFailure(String(describing: error))
      }
    }

    private func observeInterruptions() {
      guard observerTask == nil, observationTokens.isEmpty else { return }
      observeMediaServicesResets()
      if #available(iOS 27, *) {
        observeInterruptionMessages()
      } else {
        observeLegacyInterruptionNotification()
      }
    }

    /// The audio daemon restarted: the category, activation and every engine are gone.
    private func observeMediaServicesResets() {
      let sink = continuation
      // Owned by this controller; ends with the process (the controller lives for the app's lifetime).
      resetTask = Task {
        let resets = NotificationCenter.default.notifications(named: AVAudioSession.mediaServicesWereResetNotification)
        for await _ in resets { sink.yield(.mediaServicesReset) }
      }
    }

    /// iOS 27: `didBecomeInactive` (system interruption) and `resumptionRecommendation`.
    @available(iOS 27, *)
    private func observeInterruptionMessages() {
      let session = AVAudioSession.sharedInstance()
      let sink = continuation
      let events = events
      let center = NotificationCenter.default
      observationTokens = [
        center.addObserver(of: session, for: .didBecomeInactive) { message in
          guard case .systemInterruption = message.deactivationResult else { return }
          events.event("audio.interruption", ["type": "began", "api": "ios27"])
          sink.yield(.began)
        },
        center.addObserver(of: session, for: .resumptionRecommendation) { message in
          let resume = message.recommendation == .shouldResume
          events.event("audio.interruption", ["type": "ended", "should_resume": .bool(resume), "api": "ios27"])
          sink.yield(.ended(shouldResume: resume))
        },
      ]
    }

    /// iOS 26: `interruptionNotification` (deprecated from 27).
    private func observeLegacyInterruptionNotification() {
      let sink = continuation
      let events = events
      // Owned by this controller; ends with the process (the controller lives for the app's lifetime).
      observerTask = Task {
        for await notification in NotificationCenter.default.notifications(
          named: AVAudioSession.interruptionNotification)
        {
          guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
          else { continue }
          let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
          let reason =
            rawReason.map(Self.name(ofInterruptionReason:)) ?? "unknown"
          switch type {
          case .began:
            events.event("audio.interruption", ["type": "began", "reason": .string(reason), "api": "ios26"])
            sink.yield(.began)
          case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            events.event(
              "audio.interruption",
              [
                "type": "ended", "options": .int(Int(rawOptions)),
                "should_resume": .bool(options.contains(.shouldResume)),
                "reason": .string(reason), "api": "ios26",
              ])
            sink.yield(.ended(shouldResume: options.contains(.shouldResume)))
          @unknown default:
            continue
          }
        }
      }
    }
  }

  extension AVAudioSessionController {
    /// By raw value, so a case the SDK deprecates or adds does not break the build.
    fileprivate static func name(ofInterruptionReason raw: UInt) -> String {
      switch raw {
      case 0: "default"
      case 1: "app_was_suspended"
      case 2: "built_in_mic_muted"
      case 4: "route_disconnected"
      default: "reason_\(raw)"
      }
    }
  }

  public actor AVAudioSessionRouteManager: RouteManager {
    public nonisolated let routeChanges: AsyncStream<RouteChange>
    private let continuation: AsyncStream<RouteChange>.Continuation
    private let defaults: UserDefaults
    private var observerTask: Task<Void, Never>?
    private static let rulesKey = "com.jkrumm.iris.capture.routeRules"

    public init(defaults: UserDefaults = .standard, events: any CaptureEvents = NoCaptureEvents()) {
      self.defaults = defaults
      (routeChanges, continuation) = AsyncStream.makeStream(of: RouteChange.self)
      Self.logRouteChanges(to: events)
    }

    /// Every route change is an `audio.route_change` event, whether or not anything consumes `routeChanges`.
    private static func logRouteChanges(to events: any CaptureEvents) {
      // Owned by the process: the route manager lives for the app's lifetime.
      Task {
        for await notification in NotificationCenter.default.notifications(
          named: AVAudioSession.routeChangeNotification)
        {
          let session = AVAudioSession.sharedInstance()
          let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
          let previous =
            notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
          var attributes = SessionSnapshot.attributes()
          attributes["reason"] = .string(reason.map(name(of:)) ?? "unknown")
          attributes["route.current"] = .string(
            SessionSnapshot.describe(session.currentRoute.inputs + session.currentRoute.outputs))
          attributes["route.prev"] = .string(
            previous.map { SessionSnapshot.describe($0.inputs + $0.outputs) } ?? "none")
          events.event("audio.route_change", attributes)
        }
      }
    }

    private static func name(of reason: AVAudioSession.RouteChangeReason) -> String {
      switch reason {
      case .unknown: "unknown"
      case .newDeviceAvailable: "new_device_available"
      case .oldDeviceUnavailable: "old_device_unavailable"
      case .categoryChange: "category_change"
      case .override: "override"
      case .wakeFromSleep: "wake_from_sleep"
      case .noSuitableRouteForCategory: "no_suitable_route"
      case .routeConfigurationChange: "route_configuration_change"
      @unknown default: "unknown"
      }
    }

    public func currentRoute() -> RouteSnapshot {
      Self.snapshot(of: AVAudioSession.sharedInstance())
    }

    public func setPreferredInput(uid: String?) throws {
      let session = AVAudioSession.sharedInstance()
      do {
        guard let uid else {
          try session.setPreferredInput(nil)
          return
        }
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else {
          throw CaptureError.inputUnavailable(uid: uid)
        }
        try session.setPreferredInput(port)
      } catch let error as CaptureError {
        throw error
      } catch {
        throw CaptureError.sessionFailure(String(describing: error))
      }
    }

    public func rules() -> [String: String] {
      defaults.dictionary(forKey: Self.rulesKey) as? [String: String] ?? [:]
    }

    public func setRule(fingerprint: String, preferredPortUID: String?) {
      var current = rules()
      current[fingerprint] = preferredPortUID
      defaults.set(current, forKey: Self.rulesKey)
    }

    /// Starts publishing route changes. Call once after the session is configured.
    public func startObserving() {
      guard observerTask == nil else { return }
      let sink = continuation
      // Owned by this manager; ends with the process (the manager lives for the app's lifetime).
      observerTask = Task {
        for await notification in NotificationCenter.default.notifications(
          named: AVAudioSession.routeChangeNotification)
        {
          let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
          sink.yield(
            RouteChange(
              snapshot: Self.snapshot(of: AVAudioSession.sharedInstance()),
              reason: Self.map(reason)))
        }
      }
    }

    private static func snapshot(of session: AVAudioSession) -> RouteSnapshot {
      RouteSnapshot(
        availableInputs: (session.availableInputs ?? []).map(port(from:)),
        currentInput: session.currentRoute.inputs.first.map(port(from:)),
        outputUIDs: session.currentRoute.outputs.map(\.uid),
        outputNames: session.currentRoute.outputs.map(\.portName))
    }

    private static func port(from description: AVAudioSessionPortDescription) -> InputPort {
      let kind: PortKind =
        switch description.portType {
        case .builtInMic: .builtInMic
        case .bluetoothHFP: .bluetoothHFP
        case .bluetoothLE: .bluetoothLE
        case .headsetMic: .headsetMic
        case .carAudio: .carAudio
        case .usbAudio: .usb
        default: .other
        }
      return InputPort(uid: description.uid, name: description.portName, kind: kind)
    }

    private static func map(_ reason: AVAudioSession.RouteChangeReason?) -> RouteChangeReason {
      switch reason {
      case .newDeviceAvailable: .deviceAppeared
      case .oldDeviceUnavailable: .deviceDisappeared
      case .override: .userSelection
      case .categoryChange: .categoryChange
      default: .other
      }
    }
  }
#endif
