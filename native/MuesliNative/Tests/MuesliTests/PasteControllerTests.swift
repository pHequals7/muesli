import Testing
import AppKit
@testable import MuesliNativeApp

// .serialized: all tests here touch NSPasteboard.general (shared mutable state)
@Suite("PasteController — clipboard-preserving paste and keystroke simulation", .serialized)
struct PasteControllerTests {

    // MARK: - typeText tests

    @Test("typeText with empty string does not crash")
    func typeTextEmpty() {
        // Early-return guard: no CGEvents posted, no clipboard access
        PasteController.typeText("")
    }

    @Test("typeText does not modify the system clipboard")
    func typeTextPreservesClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("clipboard-sentinel", forType: .string)

        // Post a single space via CGEvent (minimal side-effect in test runner)
        PasteController.typeText(" ")

        // Clipboard must be unchanged — this is the whole point of typeText
        #expect(pasteboard.string(forType: .string) == "clipboard-sentinel")
    }

    @Test("UTF-16 encoding of SentencePiece leading-space deltas is correct")
    func sentencePieceLeadingSpaceUTF16() {
        // Nemotron streaming produces " word" (SentencePiece ▁ → " ").
        // typeText iterates Character.utf16, so verify round-trip is exact.
        let delta = " hello"
        let utf16 = Array(delta.utf16)
        // First code unit must be a space
        #expect(utf16.first == UInt16((" " as Unicode.Scalar).value))
        // All BMP characters: count == Swift character count
        #expect(utf16.count == delta.count)
        // Full round-trip
        let roundTripped = utf16.map { Character(Unicode.Scalar($0)!) }
        #expect(String(roundTripped) == delta)
    }

    @Test("UTF-16 round-trip for multi-word streaming deltas")
    func multiWordDeltaEncoding() {
        let deltas = [" world", " how are you", " testing one two"]
        for delta in deltas {
            let utf16 = Array(delta.utf16)
            let decoded = String(utf16.map { Character(Unicode.Scalar($0)!) })
            #expect(decoded == delta, "Round-trip failed for: \(delta)")
        }
    }

    // MARK: - paste() clipboard restoration

    @Test("paste with empty string is a no-op")
    func pasteEmptyIsNoOp() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "")

        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("paste temporarily writes text to clipboard for Cmd+V")
    func pasteWritesTextToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text")

        // Immediately after paste(), the clipboard holds the dictation text
        // (restoration happens asynchronously after ~500ms)
        #expect(pasteboard.string(forType: .string) == "dictated text")
    }

    @Test("paste restores clipboard after delay")
    func pasteRestoresClipboard() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("user-copied-text", forType: .string)

        PasteController.paste(text: "dictated text")
        drainMainRunLoop(for: 0.8)

        // Clipboard should be restored to the original content
        #expect(pasteboard.string(forType: .string) == "user-copied-text")
    }

    @Test("paste restores empty clipboard state")
    func pasteRestoresEmptyClipboard() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        PasteController.paste(text: "dictated text")
        drainMainRunLoop(for: 0.8)

        // Clipboard should be cleared (no lingering dictation text)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("paste restores multi-item clipboard")
    func pasteRestoresMultiItemClipboard() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Write two distinct items to the clipboard (e.g., Finder multi-file copy)
        let item1 = NSPasteboardItem()
        item1.setString("item-one", forType: .string)
        let item2 = NSPasteboardItem()
        item2.setString("item-two", forType: .string)
        pasteboard.writeObjects([item1, item2])

        let countBefore = pasteboard.pasteboardItems?.count ?? 0
        #expect(countBefore == 2)

        PasteController.paste(text: "dictated text")
        drainMainRunLoop(for: 0.8)

        // Both items should be restored
        let countAfter = pasteboard.pasteboardItems?.count ?? 0
        #expect(countAfter == 2)
        let texts = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) } ?? []
        #expect(texts == ["item-one", "item-two"])
    }

    // MARK: - Helpers

    /// Spin the main run loop so DispatchQueue.main.asyncAfter blocks fire.
    private func drainMainRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
