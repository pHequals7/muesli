import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("BackendOption")
struct BackendOptionTests {

    @Test("all options have unique models")
    func uniqueModels() {
        let models = BackendOption.all.map(\.model)
        #expect(Set(models).count == models.count, "Duplicate model in BackendOption.all")
    }

    @Test("all options have non-empty labels and descriptions")
    func labelsAndDescriptions() {
        for option in BackendOption.all {
            #expect(!option.label.isEmpty, "Empty label for \(option.model)")
            #expect(!option.description.isEmpty, "Empty description for \(option.model)")
            #expect(!option.sizeLabel.isEmpty, "Empty sizeLabel for \(option.model)")
        }
    }

    @Test("backend field is one of the known backends")
    func knownBackends() {
        let known: Set<String> = ["fluidaudio", "whisper", "qwen", "nemotron"]
        for option in BackendOption.all {
            #expect(known.contains(option.backend), "Unknown backend: \(option.backend)")
        }
    }

    @Test("Parakeet models use fluidaudio backend")
    func parakeetBackend() {
        #expect(BackendOption.parakeetMultilingual.backend == "fluidaudio")
        #expect(BackendOption.parakeetEnglish.backend == "fluidaudio")
    }

    @Test("Whisper models use whisper backend")
    func whisperBackend() {
        #expect(BackendOption.whisperSmall.backend == "whisper")
        #expect(BackendOption.whisperMedium.backend == "whisper")
        #expect(BackendOption.whisperLargeTurbo.backend == "whisper")
    }

    @Test("Nemotron uses nemotron backend")
    func nemotronBackend() {
        #expect(BackendOption.nemotronStreaming.backend == "nemotron")
        #expect(BackendOption.nemotronStreaming.model.contains("nemotron"))
    }

    @Test("whisper alias points to parakeetMultilingual")
    func whisperAlias() {
        #expect(BackendOption.whisper == BackendOption.parakeetMultilingual)
    }

    @Test("all contains all defined options")
    func allContainsAll() {
        #expect(BackendOption.all.contains(.parakeetMultilingual))
        #expect(BackendOption.all.contains(.parakeetEnglish))
        #expect(BackendOption.all.contains(.whisperSmall))
        #expect(BackendOption.all.contains(.whisperMedium))
        #expect(BackendOption.all.contains(.whisperLargeTurbo))
        #expect(BackendOption.all.count == 7)
    }

    @Test("Whisper models reference ggml format")
    func whisperGgmlModels() {
        #expect(BackendOption.whisperSmall.model.hasPrefix("ggml-"))
        #expect(BackendOption.whisperMedium.model.hasPrefix("ggml-"))
        #expect(BackendOption.whisperLargeTurbo.model.hasPrefix("ggml-"))
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
        }
    }

    @Test("OpenRouter presets are free models")
    func openRouterModelsFree() {
        #expect(!SummaryModelPreset.openRouterModels.isEmpty)
        for preset in SummaryModelPreset.openRouterModels {
            #expect(!preset.id.isEmpty)
            #expect(preset.id.contains(":free"), "OpenRouter preset should be free: \(preset.id)")
        }
    }
}

@Suite("MeetingSummaryBackendOption")
struct MeetingSummaryBackendTests {

    @Test("all options listed")
    func allOptions() {
        #expect(MeetingSummaryBackendOption.all.count == 3)
        #expect(MeetingSummaryBackendOption.all.contains(.openAI))
        #expect(MeetingSummaryBackendOption.all.contains(.openRouter))
        #expect(MeetingSummaryBackendOption.all.contains(.chatGPT))
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
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.openRouterAPIKey.isEmpty)
        #expect(config.dictationHotkey == .default)
        #expect(config.showFloatingIndicator == true)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.userName.isEmpty)
        #expect(config.customMeetingTemplates.isEmpty)
    }

    @Test("JSON encode/decode round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.openAIAPIKey = "sk-test-key-123"
        config.userName = "Test User"
        config.hasCompletedOnboarding = true
        config.defaultMeetingTemplateID = "weekly-team-meeting"
        config.customMeetingTemplates = [
            CustomMeetingTemplate(
                id: "tmpl_123",
                name: "Customer Follow-Up",
                prompt: "## Summary",
                icon: "dollarsign.circle"
            )
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.openAIAPIKey == "sk-test-key-123")
        #expect(decoded.userName == "Test User")
        #expect(decoded.hasCompletedOnboarding == true)
        #expect(decoded.defaultMeetingTemplateID == "weekly-team-meeting")
        #expect(decoded.customMeetingTemplates.count == 1)
        #expect(decoded.customMeetingTemplates.first?.name == "Customer Follow-Up")
        #expect(decoded.customMeetingTemplates.first?.icon == "dollarsign.circle")
    }

    @Test("JSON coding keys use snake_case")
    func snakeCaseKeys() throws {
        let config = AppConfig()
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["stt_backend"] != nil)
        #expect(json["stt_model"] != nil)
        #expect(json["has_completed_onboarding"] != nil)
        #expect(json["user_name"] != nil)
        #expect(json["default_meeting_template_id"] != nil)
        #expect(json["custom_meeting_templates"] != nil)
    }

    @Test("decodes with missing fields using defaults")
    func missingFieldsUseDefaults() throws {
        let json = "{\"stt_backend\": \"whisper\"}"
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.showFloatingIndicator == true)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(config.customMeetingTemplates.isEmpty)
    }

    @Test("custom templates decode missing icon with fallback")
    func customTemplateMissingIconUsesFallback() throws {
        let json = """
        {
          "custom_meeting_templates": [
            {
              "id": "tmpl_123",
              "name": "Customer Follow-Up",
              "prompt": "## Summary"
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.customMeetingTemplates.count == 1)
        #expect(config.customMeetingTemplates.first?.icon == MeetingTemplates.customIconFallback)
    }

    @Test("custom templates normalize invalid icons")
    func customTemplateInvalidIconUsesFallback() {
        let template = CustomMeetingTemplate(
            id: "tmpl_invalid",
            name: "Test",
            prompt: "Prompt",
            icon: "invalid.icon"
        )

        #expect(template.icon == MeetingTemplates.customIconFallback)
        #expect(MeetingTemplates.customDefinition(from: template).icon == MeetingTemplates.customIconFallback)
    }
}

@Suite("MeetingResummarizationPolicy")
struct MeetingResummarizationPolicyTests {

    @Test("resummarize preserves the existing meeting title")
    func preservesExistingMeetingTitle() {
        let meeting = MeetingRecord(
            id: 42,
            title: "Customer pilot follow-up",
            startTime: "2026-03-24T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            wordCount: 123,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )

        #expect(
            MeetingResummarizationPolicy.plan(for: meeting) ==
            MeetingResummarizationPlan(
                promptTitle: "Customer pilot follow-up",
                persistedTitle: "Customer pilot follow-up"
            )
        )
    }

    @Test("blank titles fall back to Meeting in prompts without overwriting storage")
    func blankMeetingTitlesFallback() {
        let meeting = MeetingRecord(
            id: 43,
            title: "   ",
            startTime: "2026-03-24T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            wordCount: 123,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )

        #expect(
            MeetingResummarizationPolicy.plan(for: meeting) ==
            MeetingResummarizationPlan(
                promptTitle: "Meeting",
                persistedTitle: "   "
            )
        )
    }
}

@Suite("Meeting template resolution")
struct MeetingTemplateResolutionTests {

    @Test("exact resolution returns nil for deleted custom templates")
    func exactResolutionReturnsNilForDeletedCustomTemplates() {
        let customTemplates = [
            CustomMeetingTemplate(
                id: "tmpl_existing",
                name: "Existing Template",
                prompt: "## Summary",
                icon: "person.2"
            )
        ]

        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: "tmpl_deleted",
                customTemplates: customTemplates
            ) == nil
        )
    }

    @Test("exact resolution still supports auto and built-in templates")
    func exactResolutionSupportsDefaultTemplates() {
        let builtIn = MeetingTemplates.builtIns.first!

        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: MeetingTemplates.autoID,
                customTemplates: []
            )?.id == MeetingTemplates.autoID
        )
        #expect(
            MeetingTemplates.resolveExactDefinition(
                id: builtIn.id,
                customTemplates: []
            )?.id == builtIn.id
        )
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
    }
}

@Suite("HotkeyConfig")
struct HotkeyConfigTests {

    @Test("default is Left Cmd")
    func defaultConfig() {
        let config = HotkeyConfig.default
        #expect(config.keyCode == 55)
        #expect(config.label == "Left Cmd")
    }

    @Test("label for known key codes")
    func knownKeyCodes() {
        #expect(HotkeyConfig.label(for: 55) == "Left Cmd")
        #expect(HotkeyConfig.label(for: 54) == "Right Cmd")
        #expect(HotkeyConfig.label(for: 63) == "Fn")
        #expect(HotkeyConfig.label(for: 59) == "Left Ctrl")
        #expect(HotkeyConfig.label(for: 58) == "Left Option")
        #expect(HotkeyConfig.label(for: 56) == "Left Shift")
    }

    @Test("unknown key code returns nil")
    func unknownKeyCode() {
        #expect(HotkeyConfig.label(for: 0) == nil)
        #expect(HotkeyConfig.label(for: 100) == nil)
    }
}
