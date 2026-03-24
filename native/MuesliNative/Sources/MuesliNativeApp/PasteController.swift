import AppKit
import ApplicationServices
import Foundation
import MuesliCore

enum PasteController {
    /// Route transcription output to either clipboard+Cmd+V or direct keystroke simulation.
    /// - Parameters:
    ///   - text: The transcribed text to insert.
    ///   - avoidClipboard: When `true`, uses `typeText(_:)` so the clipboard is never touched.
    static func insert(text: String, avoidClipboard: Bool) {
        if avoidClipboard && AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                typeText(text)
            }
        } else {
            paste(text: text)
        }
    }

    static func paste(text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()
        }
    }

    /// Type text directly via CGEvent keyboard simulation without touching the clipboard.
    /// Each Character is posted as a keydown+keyup pair with its UTF-16 code units.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fputs("[muesli-native] failed to create event source for typeText\n", stderr)
            return
        }
        for char in text {
            var utf16 = Array(char.utf16)
            utf16.withUnsafeMutableBufferPointer { buf in
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { return }
                keyDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    private static func simulatePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fputs("[muesli-native] failed to create event source for paste\n", stderr)
            return
        }
        let keyCode: CGKeyCode = 9 // V
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        commandDown?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        commandUp?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }
}
