import AppKit
import CoreServices

/// How the app was started. The system tells a login item from a launch by the user in the "open application" event it
/// sends: a login launch carries the property `lgit`. (Not device-verified for `SMAppService.mainApp` on macOS 26; if the
/// system stops sending it, every launch counts as the user's and the window opens at login too.)
enum MacLaunchOrigin {
  static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
    guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication)
    else { return false }
    return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
      == OSType(keyAELaunchedAsLogInItem)
  }
}
