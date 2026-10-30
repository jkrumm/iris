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

    public init() {
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
        throw CaptureError.sessionFailure(String(describing: error))
      }
      observeInterruptions()
    }

    public func activate() throws {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        throw CaptureError.sessionFailure(String(describing: error))
      }
    }

    public func deactivate() throws {
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
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
      let center = NotificationCenter.default
      observationTokens = [
        center.addObserver(of: session, for: .didBecomeInactive) { message in
          guard case .systemInterruption = message.deactivationResult else { return }
          sink.yield(.began)
        },
        center.addObserver(of: session, for: .resumptionRecommendation) { message in
          sink.yield(.ended(shouldResume: message.recommendation == .shouldResume))
        },
      ]
    }

    /// iOS 26: `interruptionNotification` (deprecated from 27).
    private func observeLegacyInterruptionNotification() {
      let sink = continuation
      // Owned by this controller; ends with the process (the controller lives for the app's lifetime).
      observerTask = Task {
        for await notification in NotificationCenter.default.notifications(
          named: AVAudioSession.interruptionNotification)
        {
          guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
          else { continue }
          switch type {
          case .began:
            sink.yield(.began)
          case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            sink.yield(.ended(shouldResume: options.contains(.shouldResume)))
          @unknown default:
            continue
          }
        }
      }
    }
  }

  public actor AVAudioSessionRouteManager: RouteManager {
    public nonisolated let routeChanges: AsyncStream<RouteChange>
    private let continuation: AsyncStream<RouteChange>.Continuation
    private let defaults: UserDefaults
    private var observerTask: Task<Void, Never>?
    private static let rulesKey = "com.jkrumm.iris.capture.routeRules"

    public init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
      (routeChanges, continuation) = AsyncStream.makeStream(of: RouteChange.self)
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
