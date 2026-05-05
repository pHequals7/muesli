import AppKit
import ApplicationServices
import Foundation

struct ComputerUseRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

struct ComputerUseElementCandidate: Codable, Equatable {
    let elementID: String
    let elementIndex: Int
    let role: String
    let title: String
    let label: String
    let value: String
    let help: String
    let enabled: Bool
    let frame: ComputerUseRect?
    let path: String

    enum CodingKeys: String, CodingKey {
        case elementID = "element_id"
        case elementIndex = "element_index"
        case role
        case title
        case label
        case value
        case help
        case enabled
        case frame
        case path
    }

    var normalizedText: String {
        Self.normalizedText([title, label, value, help].joined(separator: " "))
    }

    static func normalizedText(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ComputerUseScreenshotObservation: Equatable {
    let screenshotID: String
    let width: Int
    let height: Int
    let windowFrame: ComputerUseRect
    let scaleX: Double
    let scaleY: Double
    let imageDataURL: String?

    enum CodingKeys: String, CodingKey {
        case screenshotID = "screenshot_id"
        case width
        case height
        case windowFrame = "window_frame"
        case scaleX = "scale_x"
        case scaleY = "scale_y"
    }
}

extension ComputerUseScreenshotObservation: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            screenshotID: try container.decode(String.self, forKey: .screenshotID),
            width: try container.decode(Int.self, forKey: .width),
            height: try container.decode(Int.self, forKey: .height),
            windowFrame: try container.decode(ComputerUseRect.self, forKey: .windowFrame),
            scaleX: try container.decode(Double.self, forKey: .scaleX),
            scaleY: try container.decode(Double.self, forKey: .scaleY),
            imageDataURL: nil
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screenshotID, forKey: .screenshotID)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(windowFrame, forKey: .windowFrame)
        try container.encode(scaleX, forKey: .scaleX)
        try container.encode(scaleY, forKey: .scaleY)
    }
}

struct ComputerUseObservation: Codable, Equatable {
    let appName: String
    let bundleID: String
    let windowTitle: String
    let windowFrame: ComputerUseRect?
    let screenshot: ComputerUseScreenshotObservation?
    let cursorPosition: ComputerUseRect?
    let elements: [ComputerUseElementCandidate]
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case windowFrame = "window_frame"
        case screenshot
        case cursorPosition = "cursor_position"
        case elements
        case capturedAt = "captured_at"
    }
}

struct ComputerUseObservationTarget: Codable, Equatable {
    let appName: String?
    let bundleID: String?

    var displayName: String {
        if let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appName
        }
        return bundleID ?? ""
    }
}

@MainActor
final class ComputerUseElementRegistry {
    private var elements: [String: AXUIElement] = [:]
    private var indexedElements: [Int: AXUIElement] = [:]
    private var screenshot: ComputerUseScreenshotObservation?

    func clear() {
        elements.removeAll()
        indexedElements.removeAll()
        screenshot = nil
    }

    func register(_ element: AXUIElement, id: String, index: Int) {
        elements[id] = element
        indexedElements[index] = element
    }

    func element(for id: String) -> AXUIElement? {
        elements[id]
    }

    func element(for index: Int) -> AXUIElement? {
        indexedElements[index]
    }

    func registerScreenshot(_ screenshot: ComputerUseScreenshotObservation?) {
        self.screenshot = screenshot
    }

    func currentScreenshot() -> ComputerUseScreenshotObservation? {
        screenshot
    }

    var registeredIDsForTests: Set<String> {
        Set(elements.keys)
    }
}

@MainActor
enum ComputerUseObservationCapture {
    static func capture(
        registry: ComputerUseElementRegistry,
        includeScreenshot: Bool = false,
        target: ComputerUseObservationTarget? = nil,
        maxCandidates: Int = 80,
        maxDepth: Int = 8
    ) -> ComputerUseObservation {
        registry.clear()
        let app = runningApplication(for: target) ?? NSWorkspace.shared.frontmostApplication
        if target != nil, let app, !app.isActive {
            app.activate(options: [.activateAllWindows])
        }
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""
        let capturedAt = Date()

        guard AXIsProcessTrusted(), let app else {
            return ComputerUseObservation(
                appName: appName,
                bundleID: bundleID,
                windowTitle: "",
                windowFrame: nil,
                screenshot: nil,
                cursorPosition: cursorPositionObservation(),
                elements: [],
                capturedAt: capturedAt
            )
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = focusedWindow(in: axApp)
        let root = window ?? axApp
        let windowTitle = window.map { axString($0, kAXTitleAttribute) } ?? ""
        let windowFrame = window.flatMap(rect)
        let screenshot = includeScreenshot ? captureScreenshot(for: app, fallbackFrame: windowFrame) : nil
        registry.registerScreenshot(screenshot)

        var candidates: [ComputerUseElementCandidate] = []
        var visited = Set<AXUIElement>()
        walk(
            root,
            registry: registry,
            candidates: &candidates,
            visited: &visited,
            path: "0",
            depth: 0,
            maxDepth: maxDepth,
            maxCandidates: maxCandidates
        )

        return ComputerUseObservation(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            windowFrame: windowFrame.map(ComputerUseRect.init),
            screenshot: screenshot,
            cursorPosition: cursorPositionObservation(),
            elements: candidates,
            capturedAt: capturedAt
        )
    }

    nonisolated static func candidateForTests(
        elementID: String,
        elementIndex: Int? = nil,
        role: String,
        title: String,
        label: String = "",
        value: String = "",
        help: String = "",
        enabled: Bool = true,
        frame: ComputerUseRect? = nil,
        path: String = "0"
    ) -> ComputerUseElementCandidate {
        ComputerUseElementCandidate(
            elementID: elementID,
            elementIndex: elementIndex ?? Self.elementIndex(from: elementID),
            role: role,
            title: title,
            label: label,
            value: value,
            help: help,
            enabled: enabled,
            frame: frame,
            path: path
        )
    }

    private static func walk(
        _ element: AXUIElement,
        registry: ComputerUseElementRegistry,
        candidates: inout [ComputerUseElementCandidate],
        visited: inout Set<AXUIElement>,
        path: String,
        depth: Int,
        maxDepth: Int,
        maxCandidates: Int
    ) {
        guard depth <= maxDepth, candidates.count < maxCandidates, !visited.contains(element) else { return }
        visited.insert(element)

        let nextIndex = candidates.count + 1
        if let candidate = candidate(from: element, id: "e\(nextIndex)", index: nextIndex, path: path) {
            registry.register(element, id: candidate.elementID, index: candidate.elementIndex)
            candidates.append(candidate)
        }

        let children = childElements(of: element)
        for (index, child) in children.enumerated() where candidates.count < maxCandidates {
            walk(
                child,
                registry: registry,
                candidates: &candidates,
                visited: &visited,
                path: "\(path).\(index)",
                depth: depth + 1,
                maxDepth: maxDepth,
                maxCandidates: maxCandidates
            )
        }
    }

    private static func candidate(from element: AXUIElement, id: String, index: Int, path: String) -> ComputerUseElementCandidate? {
        let role = axString(element, kAXRoleAttribute)
        let title = axString(element, kAXTitleAttribute)
        let label = axString(element, kAXDescriptionAttribute)
        let value = axString(element, kAXValueAttribute)
        let help = axString(element, kAXHelpAttribute)
        let enabled = axBool(element, kAXEnabledAttribute) ?? true
        let frame = rect(element).map(ComputerUseRect.init)

        let text = ComputerUseElementCandidate.normalizedText([title, label, value, help].joined(separator: " "))
        guard !role.isEmpty || !text.isEmpty else { return nil }

        return ComputerUseElementCandidate(
            elementID: id,
            elementIndex: index,
            role: role,
            title: truncate(title, limit: 80),
            label: truncate(label, limit: 80),
            value: truncate(value, limit: 120),
            help: truncate(help, limit: 80),
            enabled: enabled,
            frame: frame,
            path: path
        )
    }

    nonisolated private static func elementIndex(from elementID: String) -> Int {
        let digits = elementID.drop { !$0.isNumber }
        return Int(digits) ?? 0
    }

    private static func focusedWindow(in axApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let element = value,
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    private static func runningApplication(for target: ComputerUseObservationTarget?) -> NSRunningApplication? {
        guard let target else { return nil }
        if let bundleID = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        }
        guard let appName = target.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty else {
            return nil
        }
        let canonical = canonicalAppName(appName)
        if let bundleID = ComputerUseExecutor.bundleIdentifierAlias(for: appName),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { app in
            guard let name = app.localizedName else { return false }
            return canonicalAppName(name) == canonical
        }
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let rawChildren = value as? [AXUIElement]
        else { return [] }
        return rawChildren
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func rect(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func cursorPositionObservation() -> ComputerUseRect {
        let point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        return ComputerUseRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private static func captureScreenshot(
        for app: NSRunningApplication,
        fallbackFrame: CGRect?
    ) -> ComputerUseScreenshotObservation? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let appWindows = windowList.filter { dict in
            guard let ownerPID = dict[kCGWindowOwnerPID] as? Int32, ownerPID == app.processIdentifier else { return false }
            guard let layer = dict[kCGWindowLayer] as? Int, layer == 0 else { return false }
            guard let bounds = cgWindowBounds(dict), bounds.width > 0, bounds.height > 0 else { return false }
            return true
        }
        let appWindow = preferredScreenshotWindow(from: appWindows, fallbackFrame: fallbackFrame)

        if let appWindow,
           let windowID = appWindow[kCGWindowNumber] as? CGWindowID,
           let frame = cgWindowBounds(appWindow) ?? fallbackFrame,
           frame.width > 0,
           frame.height > 0,
           let image = CGWindowListCreateImage(
               .null,
               .optionIncludingWindow,
               windowID,
               [.bestResolution, .boundsIgnoreFraming]
           ),
           !shouldUseDisplayFallbackForScreenshot(width: image.width, height: image.height, frame: frame) {
            return screenshotObservation(image: image, frame: frame)
        }

        guard let displayFrame = displayFrame(containing: fallbackFrame),
              let image = CGWindowListCreateImage(
                  displayFrame,
                  .optionOnScreenOnly,
                  kCGNullWindowID,
                  [.bestResolution]
              ) else { return nil }
        return screenshotObservation(image: image, frame: displayFrame)
    }

    private static func screenshotObservation(image: CGImage, frame: CGRect) -> ComputerUseScreenshotObservation {
        let width = image.width
        let height = image.height
        let scaleX = Double(width) / max(Double(frame.width), 1)
        let scaleY = Double(height) / max(Double(frame.height), 1)
        return ComputerUseScreenshotObservation(
            screenshotID: "s\(Int(Date().timeIntervalSince1970 * 1000))",
            width: width,
            height: height,
            windowFrame: ComputerUseRect(frame),
            scaleX: scaleX,
            scaleY: scaleY,
            imageDataURL: imageDataURL(image)
        )
    }

    nonisolated static func shouldUseDisplayFallbackForScreenshot(width: Int, height: Int, frame: CGRect) -> Bool {
        width < 320 || height < 240 || frame.width < 320 || frame.height < 240
    }

    private static func preferredScreenshotWindow(
        from windows: [[CFString: Any]],
        fallbackFrame: CGRect?
    ) -> [CFString: Any]? {
        guard !windows.isEmpty else { return nil }
        if let fallbackFrame, fallbackFrame.width > 0, fallbackFrame.height > 0 {
            let matching = windows
                .compactMap { window -> ([CFString: Any], CGRect)? in
                    guard let bounds = cgWindowBounds(window) else { return nil }
                    return (window, bounds)
                }
                .filter { _, bounds in bounds.intersects(fallbackFrame) }
                .sorted { lhs, rhs in
                    lhs.1.intersection(fallbackFrame).area > rhs.1.intersection(fallbackFrame).area
                }
            if let usefulMatch = matching.first(where: { !shouldUseDisplayFallbackForScreenshot(width: Int($0.1.width), height: Int($0.1.height), frame: $0.1) }) {
                return usefulMatch.0
            }
        }
        if let usefulWindow = windows.first(where: { window in
            guard let bounds = cgWindowBounds(window) else { return false }
            return !shouldUseDisplayFallbackForScreenshot(width: Int(bounds.width), height: Int(bounds.height), frame: bounds)
        }) {
            return usefulWindow
        }
        return windows.max { lhs, rhs in
            (cgWindowBounds(lhs)?.area ?? 0) < (cgWindowBounds(rhs)?.area ?? 0)
        }
    }

    private static func displayFrame(containing frame: CGRect?) -> CGRect? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }
        let targetPoint = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGEvent(source: nil)?.location
            ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
        if let display = displays.first(where: { CGDisplayBounds($0).contains(targetPoint) }) {
            return CGDisplayBounds(display)
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    private static func cgWindowBounds(_ windowInfo: [CFString: Any]) -> CGRect? {
        guard let bounds = windowInfo[kCGWindowBounds] as? [String: Any] else { return nil }
        let x = bounds["X"] as? CGFloat ?? 0
        let y = bounds["Y"] as? CGFloat ?? 0
        let width = bounds["Width"] as? CGFloat ?? 0
        let height = bounds["Height"] as? CGFloat ?? 0
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func imageDataURL(_ image: CGImage) -> String? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.62]) else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit - 1)) + "..." : value
    }

    private static func canonicalAppName(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(scalar)
                : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: #" app$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}
