import AppKit
import ApplicationServices
import Foundation

@MainActor
final class MeetingSourceWindowLocator {
    func screen(for candidate: MeetingCandidate) -> NSScreen? {
        if let pid = candidate.sourcePID,
           let screen = screenForApplication(pid: pid) {
            return screen
        }

        guard let bundleID = candidate.sourceBundleID else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        for app in apps where app.isActive {
            if let screen = screenForApplication(pid: app.processIdentifier) {
                return screen
            }
        }
        for app in apps {
            if let screen = screenForApplication(pid: app.processIdentifier) {
                return screen
            }
        }
        return nil
    }

    private func screenForApplication(pid: pid_t) -> NSScreen? {
        if let rect = focusedAXWindowRect(pid: pid),
           let screen = screenContainingAccessibilityRect(rect) {
            return screen
        }
        if let rect = largestCGWindowRect(pid: pid),
           let screen = screenContainingAccessibilityRect(rect) {
            return screen
        }
        return nil
    }

    private func focusedAXWindowRect(pid: pid_t) -> CGRect? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = windowRef as! AXUIElement
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func largestCGWindowRect(pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = windows.compactMap { info -> CGRect? in
            guard let ownerPIDValue = numberValue(info[kCGWindowOwnerPID as String]),
                  pid_t(ownerPIDValue) == pid,
                  let layerValue = numberValue(info[kCGWindowLayer as String]),
                  Int(layerValue) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = numberValue(bounds["X"]),
                  let y = numberValue(bounds["Y"]),
                  let width = numberValue(bounds["Width"]),
                  let height = numberValue(bounds["Height"]),
                  width > 0,
                  height > 0 else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        return candidates.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    private func screenContainingAccessibilityRect(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screens = NSScreen.screens
        if let containing = screens.first(where: { accessibilityFrame(for: $0).contains(center) }) {
            return containing
        }

        return screens.max { lhs, rhs in
            accessibilityFrame(for: lhs).intersection(rect).area < accessibilityFrame(for: rhs).intersection(rect).area
        }
    }

    private func accessibilityFrame(for screen: NSScreen) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func numberValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(truncating: number)
        case let double as Double:
            return CGFloat(double)
        case let int as Int:
            return CGFloat(int)
        case let cgFloat as CGFloat:
            return cgFloat
        default:
            return nil
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
