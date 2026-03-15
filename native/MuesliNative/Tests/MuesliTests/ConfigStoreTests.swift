import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let store = ConfigStore()
        let config = store.load()
        // Hotkey may have been customized by user — just verify it loaded
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() {
        let store = ConfigStore()
        let original = store.load()

        var config = original
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.meetingSummaryBackend == "openrouter")

        // Restore original
        store.save(original)
    }

    @Test("config path is in Application Support")
    func configPath() {
        let store = ConfigStore()
        let path = store.configPath().path
        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("config.json"))
    }
}
