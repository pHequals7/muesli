import Foundation
import MuesliCore

/// Input signals fed into the detector each evaluation cycle.
struct MeetingSignals {
    let micActive: Bool
    let cameraActive: Bool
    let calendarEvent: CalendarEventContext?
    let runningApps: [RunningAppInfo]
}

/// Calendar event that is currently active or started within 15 minutes.
struct CalendarEventContext {
    let id: String
    let title: String
}

/// A running application on the system.
struct RunningAppInfo {
    let bundleID: String
    let isActive: Bool  // frontmost
}

/// Result when a meeting is detected.
struct MeetingDetection: Equatable {
    let appName: String
    let meetingTitle: String?
}

/// Pure detection logic — no system dependencies, fully testable.
/// Evaluates a set of signals and decides whether a meeting is happening.
final class MeetingDetector {

    /// Dedicated meeting apps: running + mic active is a strong enough signal.
    static let dedicatedApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "us.zoom.ZoomPhone": "Zoom Phone",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
    ]

    /// Browsers: always running, so require an extra signal
    /// (calendar event or frontmost) to avoid false positives.
    static let browserApps: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.apple.Safari": "Safari",
    ]

    /// Bundle ID to exclude from detection (our own app).
    var selfBundleID: String = Bundle.main.bundleIdentifier ?? "com.muesli.app"

    /// How many consecutive idle evaluations before resetting detection state.
    static let idleResetThreshold = 10

    // MARK: - Mutable state

    /// Keys we've already triggered for. Prevents duplicate notifications.
    /// Calendar: "cal:<eventID>", Apps: the bundle ID.
    private(set) var detectedKeys = Set<String>()

    private var suppressUntil: Date?
    private var consecutiveIdleCount = 0

    // MARK: - Evaluate

    /// Returns the current meeting candidate based on system state without
    /// applying deduplication. This is useful for UI that should be derived
    /// from the latest detector state rather than edge-triggered callbacks.
    func currentDetection(_ signals: MeetingSignals, now: Date = Date()) -> MeetingDetection? {
        if let until = suppressUntil, now < until { return nil }
        guard signals.micActive || signals.cameraActive else { return nil }

        if signals.cameraActive {
            let (appName, _) = bestApp(from: signals.runningApps)
            let title = signals.calendarEvent?.title
            return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: title)
        }

        guard signals.micActive else { return nil }

        if let cal = signals.calendarEvent {
            let (appName, _) = bestApp(from: signals.runningApps)
            return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: cal.title)
        }

        for app in signals.runningApps where app.bundleID != selfBundleID {
            if let name = Self.dedicatedApps[app.bundleID] {
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        for app in signals.runningApps where app.bundleID != selfBundleID {
            if let name = Self.browserApps[app.bundleID], app.isActive {
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        return nil
    }

    /// Evaluate signals and return a detection if a meeting should be flagged.
    /// Returns nil if no meeting detected or already notified.
    func evaluate(_ signals: MeetingSignals, now: Date = Date()) -> MeetingDetection? {
        // Suppressed?
        if let until = suppressUntil, now < until { return nil }

        // Track idle to reset state after a gap (neither mic nor camera active)
        if !signals.micActive && !signals.cameraActive {
            consecutiveIdleCount += 1
            if consecutiveIdleCount >= Self.idleResetThreshold {
                detectedKeys.removeAll()
            }
            return nil
        }
        consecutiveIdleCount = 0

        // Clean up keys for apps that have quit
        let runningIDs = Set(signals.runningApps.map(\.bundleID))
        detectedKeys = detectedKeys.filter { $0.hasPrefix("cal:") || $0 == "camera" || runningIDs.contains($0) }

        // Priority 0: Camera active = strong meeting signal (nobody turns on camera outside meetings)
        if signals.cameraActive, !detectedKeys.contains("camera") {
            detectedKeys.insert("camera")
            let (appName, appBundleID) = bestApp(from: signals.runningApps)
            if let bid = appBundleID { detectedKeys.insert(bid) }
            // Also mark calendar event to prevent duplicate detection via Priority 1
            if let cal = signals.calendarEvent { detectedKeys.insert("cal:\(cal.id)") }
            let title = signals.calendarEvent?.title
            return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: title)
        }

        // Remaining checks require mic to be active
        guard signals.micActive else { return nil }

        // Priority 1: Calendar event + mic active = meeting (strongest signal)
        if let cal = signals.calendarEvent {
            let key = "cal:\(cal.id)"
            if !detectedKeys.contains(key) {
                detectedKeys.insert(key)
                let (appName, appBundleID) = bestApp(from: signals.runningApps)
                // Also mark the identified app to prevent double-triggering
                if let bid = appBundleID { detectedKeys.insert(bid) }
                return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: cal.title)
            }
        }

        // Priority 2: Dedicated meeting app + mic active
        for app in signals.runningApps {
            guard app.bundleID != selfBundleID, !detectedKeys.contains(app.bundleID) else { continue }
            if let name = Self.dedicatedApps[app.bundleID] {
                detectedKeys.insert(app.bundleID)
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        // Priority 3: Browser frontmost + mic active (weakest)
        for app in signals.runningApps {
            guard app.bundleID != selfBundleID, !detectedKeys.contains(app.bundleID) else { continue }
            if let name = Self.browserApps[app.bundleID], app.isActive {
                detectedKeys.insert(app.bundleID)
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        return nil
    }

    // MARK: - Suppression

    func suppress(for duration: TimeInterval = 120) {
        suppressUntil = Date().addingTimeInterval(duration)
    }

    func suppressWhileActive() {
        suppressUntil = Date.distantFuture
    }

    func resumeAfterCooldown() {
        suppressUntil = Date().addingTimeInterval(15)
    }

    func resetDetections() {
        detectedKeys.removeAll()
        consecutiveIdleCount = 0
    }

    // MARK: - Helpers

    /// Find the best display name and bundle ID from running apps (prefer dedicated, then browser).
    private func bestApp(from apps: [RunningAppInfo]) -> (name: String?, bundleID: String?) {
        for app in apps where app.bundleID != selfBundleID {
            if let name = Self.dedicatedApps[app.bundleID] { return (name, app.bundleID) }
        }
        for app in apps where app.bundleID != selfBundleID {
            if let name = Self.browserApps[app.bundleID], app.isActive { return (name, app.bundleID) }
        }
        return (nil, nil)
    }
}
