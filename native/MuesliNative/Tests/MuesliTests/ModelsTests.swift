import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("BackendOption")
struct BackendOptionTests {

    @Test("all options have unique backends")
    func uniqueBackends() {
        let backends = BackendOption.all.map(\.backend)
        #expect(Set(backends).count == backends.count)
    }

    @Test("whisper and qwen are available")
    func defaultOptions() {
        #expect(BackendOption.all.contains(.whisper))
        #expect(BackendOption.all.contains(.qwen))
    }

    @Test("whisper defaults to mlx-community model")
    func whisperModel() {
        #expect(BackendOption.whisper.model.contains("mlx-community"))
        #expect(BackendOption.whisper.model.contains("whisper"))
    }
}

@Suite("SummaryModelPreset")
struct SummaryModelPresetTests {

    @Test("OpenAI presets have valid model IDs")
    func openAIModels() {
        #expect(!SummaryModelPreset.openAIModels.isEmpty)
        for preset in SummaryModelPreset.openAIModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
            #expect(!preset.id.contains("/"), "OpenAI model IDs should not contain slash: \(preset.id)")
        }
    }

    @Test("OpenRouter presets are free models")
    func openRouterModelsFree() {
        #expect(!SummaryModelPreset.openRouterModels.isEmpty)
        for preset in SummaryModelPreset.openRouterModels {
            #expect(!preset.id.isEmpty)
            #expect(!preset.label.isEmpty)
            #expect(preset.id.contains(":free"), "OpenRouter preset should be free: \(preset.id)")
            #expect(preset.label.lowercased().contains("free"), "Label should mention free: \(preset.label)")
        }
    }

    @Test("OpenRouter presets have context window in label")
    func openRouterContextLabels() {
        for preset in SummaryModelPreset.openRouterModels {
            #expect(preset.label.contains("ctx"), "Label should mention context: \(preset.label)")
        }
    }

    @Test("first OpenAI preset is the default")
    func openAIDefault() {
        #expect(SummaryModelPreset.openAIModels.first?.id == "gpt-5-mini")
    }
}

@Suite("MeetingSummaryBackendOption")
struct MeetingSummaryBackendTests {

    @Test("all options listed")
    func allOptions() {
        #expect(MeetingSummaryBackendOption.all.count == 2)
        #expect(MeetingSummaryBackendOption.all.contains(.openAI))
        #expect(MeetingSummaryBackendOption.all.contains(.openRouter))
    }

    @Test("backend strings are lowercase")
    func backendStrings() {
        #expect(MeetingSummaryBackendOption.openAI.backend == "openai")
        #expect(MeetingSummaryBackendOption.openRouter.backend == "openrouter")
    }
}

@Suite("AppConfig")
struct AppConfigTests {

    @Test("default values")
    func defaults() {
        let config = AppConfig()
        #expect(config.sttBackend == BackendOption.whisper.backend)
        #expect(config.sttModel == BackendOption.whisper.model)
        #expect(config.meetingSummaryBackend == "openai")
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.openRouterAPIKey.isEmpty)
        #expect(config.openAIModel.isEmpty)
        #expect(config.openRouterModel.isEmpty)
        #expect(config.dictationHotkey == .default)
        #expect(config.showFloatingIndicator == true)
        #expect(config.autoRecordMeetings == false)
    }

    @Test("JSON encode/decode round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.openAIAPIKey = "sk-test-key-123"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.meetingSummaryBackend = "openrouter"
        config.autoRecordMeetings = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.openAIAPIKey == "sk-test-key-123")
        #expect(decoded.openAIModel == "gpt-5.4-pro")
        #expect(decoded.openRouterAPIKey == "sk-or-test")
        #expect(decoded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(decoded.meetingSummaryBackend == "openrouter")
        #expect(decoded.autoRecordMeetings == true)
    }

    @Test("JSON coding keys use snake_case")
    func snakeCaseKeys() throws {
        let config = AppConfig()
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["stt_backend"] != nil)
        #expect(json["stt_model"] != nil)
        #expect(json["meeting_summary_backend"] != nil)
        #expect(json["openai_api_key"] != nil)
        #expect(json["openrouter_api_key"] != nil)
        #expect(json["openai_model"] != nil)
        #expect(json["openrouter_model"] != nil)
    }

    @Test("decodes with missing fields using defaults")
    func missingFieldsUseDefaults() throws {
        let json = "{\"hotkey\": \"left_command_hold\"}"
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.sttBackend == BackendOption.whisper.backend)
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.openRouterAPIKey.isEmpty)
        #expect(config.showFloatingIndicator == true)
    }
}

@Suite("DictationState")
struct DictationStateTests {
    @Test("raw values")
    func rawValues() {
        #expect(DictationState.idle.rawValue == "idle")
        #expect(DictationState.preparing.rawValue == "preparing")
        #expect(DictationState.recording.rawValue == "recording")
        #expect(DictationState.transcribing.rawValue == "transcribing")
    }
}

@Suite("CGPointCodable")
struct CGPointCodableTests {

    @Test("keyed round-trip")
    func keyedRoundTrip() throws {
        let point = CGPointCodable(x: 100.5, y: 200.0)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CGPointCodable.self, from: data)
        #expect(decoded.x == 100.5)
        #expect(decoded.y == 200.0)
    }

    @Test("decodes from array format")
    func arrayDecode() throws {
        let json = "[42.0, 84.0]"
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CGPointCodable.self, from: data)
        #expect(decoded.x == 42.0)
        #expect(decoded.y == 84.0)
    }
}

@Suite("WordCount")
struct WordCountTests {

    @Test("basic counting")
    func basicCount() {
        #expect(DictationStore.countWords(in: "hello world") == 2)
        #expect(DictationStore.countWords(in: "one") == 1)
        #expect(DictationStore.countWords(in: "") == 0)
    }

    @Test("handles multiple whitespace")
    func multipleWhitespace() {
        #expect(DictationStore.countWords(in: "hello   world") == 2)
        #expect(DictationStore.countWords(in: "  leading and trailing  ") == 3)
        #expect(DictationStore.countWords(in: "tabs\there\ttoo") == 3)
        #expect(DictationStore.countWords(in: "newlines\ncount\ntoo") == 3)
    }
}
