import AppKit
import ApplicationServices
import Foundation
import MuesliCore

enum PasteController {
    /// How long to wait after simulating Cmd+V before restoring the clipboard.
    /// The receiving app must have consumed the paste data within this window.
    private static let clipboardRestoreDelay: TimeInterval = 0.5

    /// Paste text into the active app via clipboard, then restore the original clipboard contents.
    ///
    /// Flow: save clipboard → write text → Cmd+V → restore clipboard after delay.
    /// If the clipboard cannot be saved (e.g. lazy-provided data), falls back to a simple
    /// paste without restoration.
    static func paste(text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents (all types) so we can restore after paste.
        let savedItems = saveClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            // Restore the original clipboard contents after the receiving app has consumed the paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                restoreClipboard(pasteboard, from: savedItems)
            }
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

    // MARK: - Private

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

    /// Snapshot every item on the pasteboard so we can put it back later.
    /// Returns an array of (type, data) pairs for each item.
    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    pairs.append((type, data))
                }
            }
            if !pairs.isEmpty {
                saved.append(pairs)
            }
        }
        return saved
    }

    /// Restore previously saved clipboard contents. If nothing was saved, clears the clipboard
    /// so dictation text doesn't linger.
    private static func restoreClipboard(_ pasteboard: NSPasteboard, from saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        pasteboard.clearContents()
        if saved.isEmpty { return }
        for itemPairs in saved {
            let item = NSPasteboardItem()
            for (type, data) in itemPairs {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }
}
