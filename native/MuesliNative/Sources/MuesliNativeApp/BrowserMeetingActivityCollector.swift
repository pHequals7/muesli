import AppKit
import ApplicationServices
import Foundation

@MainActor
final class BrowserMeetingActivityCollector {
    private let browserBundleIDs = Set(MeetingCandidateResolver.browserApps.keys)
    private let cachedMeetingTTL: TimeInterval = 8
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]

    func collect() -> [BrowserMeetingContext] {
        let now = Date()
        let browserApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return browserBundleIDs.contains(bundleID)
        }
        let runningBrowserIDs = Set(browserApps.compactMap(\.bundleIdentifier))

        let liveMeetings: [BrowserMeetingContext] = browserApps.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            guard let normalized = normalizedFocusedURL(for: app) else {
                if app.isActive {
                    cachedMeetings.removeValue(forKey: bundleID)
                }
                return nil
            }

            let context = BrowserMeetingContext(
                bundleID: bundleID,
                appName: app.localizedName ?? MeetingCandidateResolver.browserApps[bundleID] ?? bundleID,
                pid: app.processIdentifier,
                url: normalized.url,
                normalizedID: normalized.id,
                platform: normalized.platform,
                isFocused: app.isActive,
                requiresMediaActivity: normalized.requiresMediaActivity
            )
            cachedMeetings[bundleID] = CachedBrowserMeeting(context: context, observedAt: now)
            return context
        }

        let liveBundleIDs = Set(liveMeetings.map(\.bundleID))
        cachedMeetings = cachedMeetings.filter { bundleID, cached in
            runningBrowserIDs.contains(bundleID) && now.timeIntervalSince(cached.observedAt) <= cachedMeetingTTL
        }

        let cachedOnlyMeetings = cachedMeetings.values
            .filter { !liveBundleIDs.contains($0.context.bundleID) }
            .map { cached in
                BrowserMeetingContext(
                    bundleID: cached.context.bundleID,
                    appName: cached.context.appName,
                    pid: cached.context.pid,
                    url: cached.context.url,
                    normalizedID: cached.context.normalizedID,
                    platform: cached.context.platform,
                    isFocused: false,
                    requiresMediaActivity: cached.context.requiresMediaActivity
                )
            }

        return liveMeetings + cachedOnlyMeetings
    }

    private func normalizedFocusedURL(for app: NSRunningApplication) -> NormalizedMeetingURL? {
        if let normalized = normalizedAXDocumentURL(for: app) {
            return normalized
        }

        guard app.isActive,
              let bundleID = app.bundleIdentifier,
              let url = activeBrowserURLViaAppleScript(bundleID: bundleID) else {
            return nil
        }
        return MeetingURLNormalizer.normalizeBrowserActivity(url)
    }

    private func normalizedAXDocumentURL(for app: NSRunningApplication) -> NormalizedMeetingURL? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }

        let axWindow = (window as! AXUIElement)
        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &documentRef) == .success,
              let rawURL = documentRef as? String else {
            return nil
        }

        return MeetingURLNormalizer.normalizeBrowserActivity(rawURL)
    }

    private func activeBrowserURLViaAppleScript(bundleID: String) -> String? {
        let source: String
        switch bundleID {
        case "com.apple.Safari":
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac":
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue,
              !output.isEmpty else {
            return nil
        }
        return output
    }
}

private struct CachedBrowserMeeting {
    let context: BrowserMeetingContext
    let observedAt: Date
}
