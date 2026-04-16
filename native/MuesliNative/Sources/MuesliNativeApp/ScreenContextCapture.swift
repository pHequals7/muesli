import AppKit
import ApplicationServices
import Vision

// MARK: - Dictation context (Accessibility API — deterministic, low-token)

struct DictationContext {
    let appName: String
    let bundleID: String
    let documentContext: String
    let selectedText: String
    let url: String?
}

enum DictationContextCapture {

    /// Captures focused app name + text context via Accessibility API.
    /// Lightweight and deterministic — no screenshots, no OCR.
    static func capture() -> DictationContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""

        var docContext = ""
        var selectedText = ""

        if let app, AXIsProcessTrusted(), let focusedElement = focusedUIElement(for: app) {
            docContext = textBeforeCursor(focusedElement, maxChars: 200)
            selectedText = axStringValue(focusedElement, attribute: kAXSelectedTextAttribute as String)
        }

        let url = browserURL(for: app)

        fputs("[muesli-native] dictation context: app=\(appName) docContext=\(docContext.count) chars selectedText=\(selectedText.count) chars url=\(url ?? "none")\n", stderr)

        return DictationContext(
            appName: appName,
            bundleID: bundleID,
            documentContext: docContext,
            selectedText: selectedText,
            url: url
        )
    }

    /// Formats for the post-processor LLM prompt. Compact, high-signal.
    static func formatForPrompt(_ ctx: DictationContext) -> String {
        var parts = "App: \(ctx.appName)"
        if let url = ctx.url {
            parts += " (\(url))"
        }
        if !ctx.documentContext.isEmpty {
            parts += "\nDocument context: \(ctx.documentContext)"
        }
        if !ctx.selectedText.isEmpty {
            parts += "\nSelected text: \(ctx.selectedText)"
        }
        return parts
    }

    /// Compact format for the app_context DB column.
    static func formatForStorage(_ ctx: DictationContext) -> String {
        var parts = "\(ctx.appName)|\(ctx.bundleID)"
        if let url = ctx.url { parts += "|\(url)" }
        if !ctx.documentContext.isEmpty {
            parts += "|doc:\(ctx.documentContext)"
        }
        return parts
    }

    // MARK: - Accessibility helpers

    private static func focusedUIElement(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// Reads up to `maxChars` of text before the cursor using the parameterized
    /// AX string-for-range attribute. Falls back to suffix of full value if unsupported.
    private static func textBeforeCursor(_ element: AXUIElement, maxChars: Int) -> String {
        // Try cursor-aware read via kAXSelectedTextRangeAttribute + kAXStringForRangeParameterizedAttribute
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                let cursorPos = cfRange.location
                let prefixLen = min(cursorPos, maxChars)
                if prefixLen > 0 {
                    var sliceRange = CFRange(location: cursorPos - prefixLen, length: prefixLen)
                    let axRange: AXValue? = AXValueCreate(.cfRange, &sliceRange)
                    if let axRange {
                        var sliceRef: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(
                            element,
                            kAXStringForRangeParameterizedAttribute as CFString,
                            axRange,
                            &sliceRef
                        ) == .success, let text = sliceRef as? String {
                            return text
                        }
                    }
                }
            }
        }

        // Fallback: read full value only if the document is small enough that the
        // IPC cost is acceptable. Skip for large documents (>5000 chars) to avoid
        // copying the entire text buffer across the process boundary.
        var charCountRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &charCountRef) == .success,
           let count = charCountRef as? Int, count > 5000 {
            return ""
        }
        let full = axStringValue(element, attribute: kAXValueAttribute as String)
        if full.count > maxChars {
            return "..." + String(full.suffix(maxChars))
        }
        return full
    }

    private static func axStringValue(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let str = value as? String else { return "" }
        return str
    }

    private static func browserURL(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let browserBundles = [
            "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
            "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac"
        ]
        guard browserBundles.contains(app.bundleIdentifier ?? "") else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }

        let axWindow = (window as! AXUIElement)
        var urlValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &urlValue) == .success,
           let url = urlValue as? String, !url.isEmpty {
            if let parsed = URL(string: url) {
                return "\(parsed.host ?? "")\(parsed.path)"
            }
            return String(url.prefix(100))
        }
        return nil
    }
}

// MARK: - Meeting context (Screenshot + OCR — richer, for cloud LLMs)

struct ScreenContext {
    let appName: String
    let bundleID: String
    let ocrText: String
    let capturedAt: Date
}

enum ScreenContextCapture {

    /// Captures a screenshot of the focused window and runs on-device OCR.
    /// Used for meeting context only — heavier than AX but provides visual content.
    static func captureOnce() async -> ScreenContext? {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""

        let pid = app?.processIdentifier ?? 0
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let appWindow = windowList.first(where: { dict in
            guard let ownerPID = dict[kCGWindowOwnerPID] as? Int32, ownerPID == pid else { return false }
            guard let layer = dict[kCGWindowLayer] as? Int, layer == 0 else { return false }
            return true
        })
        guard let windowID = appWindow?[kCGWindowNumber] as? CGWindowID else {
            fputs("[muesli-native] screen context: no window found for \(appName)\n", stderr)
            return nil
        }
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            fputs("[muesli-native] screen context: screenshot capture failed\n", stderr)
            return nil
        }

        do {
            let text = try await ocrImage(image)
            fputs("[muesli-native] screen context: captured \(text.count) chars from \(appName)\n", stderr)
            return ScreenContext(
                appName: appName,
                bundleID: bundleID,
                ocrText: text,
                capturedAt: Date()
            )
        } catch {
            fputs("[muesli-native] screen context: OCR failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func ocrImage(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Dispatch to background queue to avoid blocking the Swift cooperative thread pool
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let text = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: text)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.usesCPUOnly = true

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Meeting periodic capture

actor MeetingScreenContextCollector {
    private struct Snapshot {
        let timestamp: Date
        let appName: String
        let ocrText: String
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var snapshots: [Snapshot] = []
    private var captureTask: Task<Void, Never>?

    func startPeriodicCapture(interval: TimeInterval = 60) {
        captureTask?.cancel()
        captureTask = Task {
            while !Task.isCancelled {
                if let context = await ScreenContextCapture.captureOnce() {
                    snapshots.append(Snapshot(
                        timestamp: context.capturedAt,
                        appName: context.appName,
                        ocrText: String(context.ocrText.prefix(1000))
                    ))
                }
                // Cancellation wakes the sleep; Task.isCancelled gates the next iteration
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    @discardableResult
    func stopAndDrain() -> String {
        captureTask?.cancel()
        captureTask = nil
        guard !snapshots.isEmpty else { return "" }

        var deduped: [Snapshot] = []
        for snapshot in snapshots {
            if let last = deduped.last, last.ocrText == snapshot.ocrText {
                continue
            }
            deduped.append(snapshot)
        }
        snapshots = []

        let result = deduped.map { entry in
            "[\(Self.timeFormatter.string(from: entry.timestamp))] \(entry.appName):\n\(entry.ocrText)"
        }.joined(separator: "\n\n")

        return String(result.prefix(5000))
    }
}
