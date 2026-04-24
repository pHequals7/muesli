import AppKit
import ApplicationServices
import Foundation

@MainActor
final class BrowserMeetingActivityCollector {
    private let browserBundleIDs = Set(MeetingCandidateResolver.browserApps.keys)

    func collect() -> [BrowserMeetingContext] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  browserBundleIDs.contains(bundleID),
                  let normalized = normalizedFocusedURL(for: app) else {
                return nil
            }

            return BrowserMeetingContext(
                bundleID: bundleID,
                appName: app.localizedName ?? MeetingCandidateResolver.browserApps[bundleID] ?? bundleID,
                pid: app.processIdentifier,
                url: normalized.url,
                normalizedID: normalized.id,
                platform: normalized.platform,
                isFocused: app.isActive
            )
        }
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
        return MeetingURLNormalizer.normalize(url)
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

        return MeetingURLNormalizer.normalize(rawURL)
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
