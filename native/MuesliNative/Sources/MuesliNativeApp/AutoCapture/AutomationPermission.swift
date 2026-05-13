import AppKit
import ApplicationServices
import Foundation
import os

// MARK: - AutomationPermissionStatus

/// Outcome of probing macOS Automation permission for a single target bundle.
///
/// Mirrors the cases returned by `AEDeterminePermissionToAutomateTarget` so
/// callers can distinguish "denied" (user said no) from "not determined"
/// (system has never asked). See ADR-0003 for the rationale and for the
/// fallback when no non-prompting probe is available on a given macOS version.
enum AutomationPermissionStatus: Equatable {
    /// Permission is currently granted to send AppleEvents to the target.
    case granted

    /// User explicitly denied permission in System Settings → Privacy →
    /// Automation. The persistent banner in the Auto-Capture settings pane is
    /// shown for this state.
    case denied

    /// macOS has never asked the user about this target. The first AppleScript
    /// invocation will trigger the system prompt.
    case notDetermined

    /// The target app is not currently running. We treat this as
    /// `notDetermined` because the system cannot answer until the target is
    /// up; the caller can choose to wait until the browser launches.
    case targetMissing

    /// Any other status code from `AEDeterminePermissionToAutomateTarget`.
    /// Kept distinct so we can log it without conflating with denials.
    case error(OSStatus)

    /// True if the system has decided yes/no. `notDetermined` and
    /// `targetMissing` are treated as "ask again later".
    var isDecisive: Bool {
        self == .granted || self == .denied
    }
}

// MARK: - AutomationPermissionProbe

/// Probes macOS Automation permission for an AppleScript target by bundle ID.
///
/// `AEDeterminePermissionToAutomateTarget` is the only non-prompting probe
/// the system offers (when `askUserIfNeeded` is `false`). When called with
/// `askUserIfNeeded == true` it triggers the standard Automation prompt
/// macOS shows the first time an app tries to script another. The probe is
/// per-(source, target, eventClass, eventID); we use `typeWildCard` for the
/// event class and ID so the answer covers any AppleScript we might send.
///
/// This type is intentionally stateless and pure-static so it can be used as
/// a default dependency in `BrowserURLPoller` without any singleton lifecycle.
@MainActor
enum AutomationPermissionProbe {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture")

    /// FourCharCode `'****'` — accepts any AppleEvent class/ID. The system
    /// answers permission for any AppleScript verb we might later send.
    private static let wildcard: OSType = 0x2a2a2a2a // '****'

    /// `errAEEventNotPermitted` from `<CarbonCore/MacErrors.h>`. Inlined
    /// because Swift's import of the constant is not always available.
    private static let errAEEventNotPermitted: OSStatus = -1743

    /// `errAEEventWouldRequireUserConsent` — returned when the system would
    /// prompt the user but `askUserIfNeeded` was `false`.
    private static let errAEEventWouldRequireUserConsent: OSStatus = -1744

    /// `procNotFound` — target app not running.
    private static let procNotFound: OSStatus = -600

    /// Probe permission without surfacing a system prompt. Safe to call from
    /// background timers because it does not block on UI.
    static func status(forBundleID bundleID: String) -> AutomationPermissionStatus {
        evaluate(bundleID: bundleID, askUserIfNeeded: false)
    }

    /// Probe permission, allowing the system to surface its prompt when the
    /// answer is undetermined. Returns `.notDetermined` if the user has not
    /// answered the prompt yet (the prompt remains on screen).
    static func requestPermission(forBundleID bundleID: String) -> AutomationPermissionStatus {
        evaluate(bundleID: bundleID, askUserIfNeeded: true)
    }

    private static func evaluate(bundleID: String, askUserIfNeeded: Bool) -> AutomationPermissionStatus {
        guard !bundleID.isEmpty else { return .error(OSStatus(-50)) }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descPointer = target.aeDesc else {
            logger.notice("automation_probe descriptor_missing bundle=\(bundleID, privacy: .public)")
            return .error(OSStatus(-50))
        }
        let status = AEDeterminePermissionToAutomateTarget(
            descPointer,
            AEEventClass(wildcard),
            AEEventID(wildcard),
            askUserIfNeeded
        )
        return map(status: status, bundleID: bundleID)
    }

    private static func map(status: OSStatus, bundleID: String) -> AutomationPermissionStatus {
        switch status {
        case noErr:
            return .granted
        case errAEEventNotPermitted:
            return .denied
        case errAEEventWouldRequireUserConsent:
            return .notDetermined
        case procNotFound:
            return .targetMissing
        default:
            logger.notice("automation_probe unexpected_status bundle=\(bundleID, privacy: .public) os_status=\(status, privacy: .public)")
            return .error(status)
        }
    }
}
