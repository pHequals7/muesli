import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("SoundController")
struct SoundControllerTests {

    @Test("playDictationStart with enabled=false does not throw")
    func playStartDisabled() {
        // NSSound.play() is a no-op in the test runner (no audio device required)
        SoundController.playDictationStart(enabled: false)
    }

    @Test("playDictationInsert with enabled=false does not throw")
    func playInsertDisabled() {
        SoundController.playDictationInsert(enabled: false)
    }

    @Test("playDictationStart with enabled=true does not throw")
    func playStartEnabled() {
        SoundController.playDictationStart(enabled: true)
    }

    @Test("playDictationInsert with enabled=true does not throw")
    func playInsertEnabled() {
        SoundController.playDictationInsert(enabled: true)
    }
}

@Suite("MenuBarIconRenderer")
struct MenuBarIconRendererTests {

    @Test("make() returns a non-nil image")
    func makeReturnsImage() {
        let image = MenuBarIconRenderer.make()
        #expect(image != nil)
    }

    @Test("make() returns a template image for menu bar adaptation")
    func makeIsTemplate() {
        let image = MenuBarIconRenderer.make()
        #expect(image?.isTemplate == true)
    }

    @Test("make() returns a non-zero size image")
    func makeHasSize() {
        let image = MenuBarIconRenderer.make()
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }
}
