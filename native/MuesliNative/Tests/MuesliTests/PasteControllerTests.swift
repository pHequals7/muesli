import Testing
import AppKit
@testable import MuesliNativeApp

// .serialized: all tests here touch NSPasteboard.general (shared mutable state)
@Suite("PasteController.typeText — clipboard-free keystroke simulation", .serialized)
struct PasteControllerTypeTextTests {

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

    // MARK: - insert(text:avoidClipboard:) routing

    @Test("insert with avoidClipboard:false writes to clipboard")
    func insertWritesToClipboardWhenEnabled() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        PasteController.insert(text: "hello", avoidClipboard: false)

        // paste() sets clipboard contents before firing Cmd+V
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test("insert with avoidClipboard:true does not touch clipboard")
    func insertPreservesClipboardWhenDisabled() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("clipboard-sentinel", forType: .string)

        PasteController.insert(text: "hello", avoidClipboard: true)

        // typeText() must not modify the clipboard
        #expect(pasteboard.string(forType: .string) == "clipboard-sentinel")
    }
}
