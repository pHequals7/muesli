import Foundation
import MuesliCore

struct BackendOption: Equatable {
    let backend: String
    let model: String
    let label: String
    let sizeLabel: String
    let description: String
    let recommended: Bool

    static let parakeetMultilingual = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        label: "Parakeet v3",
        sizeLabel: "~450 MB",
        description: "Multilingual, 25 languages. Runs on Apple Neural Engine.",
        recommended: true
    )

    static let parakeetEnglish = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        label: "Parakeet v2",
        sizeLabel: "~450 MB",
        description: "English-only, highest recall. Runs on Apple Neural Engine.",
        recommended: false
    )

    static let whisperSmall = BackendOption(
        backend: "whisper",
        model: "ggml-small.en-q5_1",
        label: "Whisper Small",
        sizeLabel: "~190 MB",
        description: "Fast, English-optimized. Quantized for smaller download.",
        recommended: false
    )

    static let whisperMedium = BackendOption(
        backend: "whisper",
        model: "ggml-medium.en",
        label: "Whisper Medium",
        sizeLabel: "~1.5 GB",
        description: "Better accuracy, English-only. Good balance of speed and quality.",
        recommended: false
    )

    static let whisperLargeTurbo = BackendOption(
        backend: "whisper",
        model: "ggml-large-v3-turbo-q5_0",
        label: "Whisper Large Turbo",
        sizeLabel: "~600 MB",
        description: "Highest accuracy, multilingual. Quantized for faster inference.",
        recommended: false
    )

    static let nemotronStreaming = BackendOption(
        backend: "nemotron",
        model: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
        label: "Nemotron Streaming (Experimental)",
        sizeLabel: "~600 MB",
        description: "Experimental. NVIDIA streaming RNNT. English-only. Handsfree mode only. No punctuation (RNNT limitation). Append-only — no corrections.",
        recommended: false
    )

    static let canaryQwen = BackendOption(
        backend: "canary",
        model: "phequals/canary-qwen-2.5b-coreml-int8",
        label: "Canary Qwen",
        sizeLabel: "~2.5 GB",
        description: "INT8 CoreML, autoregressive, experimental. English-first. First use warms up slowly. Final transcript after stop in v1.",
        recommended: false
    )

    static let cohereTranscribe = BackendOption(
        backend: "cohere",
        model: "phequals/cohere-transcribe-coreml-mixed-precision",
        label: "Cohere Transcribe",
        sizeLabel: "~3.8 GB",
        description: "Mixed precision (FP16 encoder + INT8 decoder). English. High accuracy (#1 Open ASR Leaderboard). Final transcript after stop. May decode hallucinated text during silence — use in quiet environments or with VAD.",
        recommended: false
    )

    // Default alias
    static let whisper = parakeetMultilingual

    static let parakeetFamily: [BackendOption] = [
        .parakeetMultilingual, .parakeetEnglish,
    ]

    static let whisperFamily: [BackendOption] = [
        .whisperSmall, .whisperMedium, .whisperLargeTurbo,
    ]

    static let experimental: [BackendOption] = [
        .qwen3Asr, .canaryQwen, .nemotronStreaming,
    ]

    /// Models available for download and use.
    static let all: [BackendOption] = parakeetFamily + [.cohereTranscribe] + whisperFamily + experimental
    

    static let qwen3Asr = BackendOption(
        backend: "qwen",
        model: "FluidInference/qwen3-asr-0.6b-coreml",
        label: "Qwen3 ASR",
        sizeLabel: "~1.3 GB",
        description: "Multilingual, 52 languages. Slower than Parakeet (~2-3s). First use takes ~30s to warm up.",
        recommended: false
    )

    /// Models coming soon — shown greyed out in the Models tab.
    static let comingSoon: [BackendOption] = []

    /// Only models that have been downloaded and are ready for inference.
    static var downloaded: [BackendOption] {
        all.filter { $0.isDownloaded }
    }

    /// Check if this model's files exist on disk.
    var isDownloaded: Bool {
        let fm = FileManager.default
        switch backend {
        case "whisper":
            let filename = model.hasSuffix(".bin") ? model : "\(model).bin"
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/\(filename)")
            return fm.fileExists(atPath: path.path)
        case "fluidaudio":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if model.contains("parakeet") {
                let version = model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    return contents.contains { $0.lastPathComponent.contains("parakeet") && $0.lastPathComponent.contains(version) }
                }
            }
            return false
        case "qwen":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            return fm.fileExists(atPath: supportDir.appendingPathComponent("int8/vocab.json").path)
                || fm.fileExists(atPath: supportDir.appendingPathComponent("f32/vocab.json").path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms/encoder/encoder_int8.mlmodelc")
            return fm.fileExists(atPath: path.path)
        case "canary":
            return CanaryQwenModelStore.isAvailableLocally()
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        default:
            return false
        }
    }
}

struct SummaryModelPreset {
    let id: String
    let label: String

    static let openAIModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-pro", label: "GPT-5.4 Pro"),
        SummaryModelPreset(id: "gpt-5-mini", label: "GPT-5 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let chatGPTModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
        SummaryModelPreset(id: "gpt-4o", label: "GPT-4o"),
    ]

    static let openRouterModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "stepfun/step-3.5-flash:free", label: "Step 3.5 Flash (free, 256k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super 120B (free, 262k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-nano-30b-a3b:free", label: "Nemotron 3 Nano 30B (free, 256k ctx)"),
        SummaryModelPreset(id: "arcee-ai/trinity-large-preview:free", label: "Trinity Large (free, 131k ctx)"),
    ]
}

struct MeetingSummaryBackendOption: Equatable {
    let backend: String
    let label: String

    static let openAI = MeetingSummaryBackendOption(
        backend: "openai",
        label: "OpenAI"
    )

    static let openRouter = MeetingSummaryBackendOption(
        backend: "openrouter",
        label: "OpenRouter"
    )

    static let chatGPT = MeetingSummaryBackendOption(
        backend: "chatgpt",
        label: "ChatGPT"
    )

    static let all: [MeetingSummaryBackendOption] = [.openAI, .openRouter, .chatGPT]
}

struct PostProcessorOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sizeLabel: String
    let description: String
    let downloadURL: URL
    let filename: String

    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/postproc-\(id)", isDirectory: true)
    }

    var modelURL: URL {
        cacheDirectory.appendingPathComponent(filename)
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    // Fine-tuned Qwen3-0.6B trained on Muesli dictation correction data.
    // HF repo must be public (or token-gated) before distributing alpha builds.
    static let finetunedV2 = PostProcessorOption(
        id: "qwen3-postproc-v2",
        label: "Post-Proc v2 (Finetuned)",
        sizeLabel: "~390 MB",
        description: "Fine-tuned on Muesli dictation data. Best for filler removal, deletion cues, and spoken list formatting.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen3-postproc-v2/resolve/main/qwen3-postproc-v2-q4_k_m.gguf")!,
        filename: "qwen3-postproc-v2-q4_k_m.gguf"
    )

    // Vanilla Qwen3.5-0.8B. Stable for basic cleanup; does not reliably convert spoken list cues.
    static let qwen35_0_8b = PostProcessorOption(
        id: "qwen35-0.8b",
        label: "Qwen3.5 0.8B",
        sizeLabel: "~533 MB",
        description: "Vanilla Qwen3.5-0.8B. Good for typo correction and filler removal. Spoken list formatting is unreliable.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        filename: "Qwen3.5-0.8B-Q4_K_M.gguf"
    )

    static let all: [PostProcessorOption] = [.finetunedV2, .qwen35_0_8b]

    static let defaultSystemPrompt = """
    Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.

    You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.

    Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
    """
}

struct CustomWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var word: String
    var replacement: String?

    var displayLabel: String {
        if let replacement, !replacement.isEmpty {
            return "\(word) → \(replacement)"
        }
        return word
    }

    var targetWord: String {
        replacement ?? word
    }
}

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16 = 55
    var label: String = "Left Cmd"

    static func label(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Left Cmd"
        case 54: return "Right Cmd"
        case 63: return "Fn"
        case 59: return "Left Ctrl"
        case 62: return "Right Ctrl"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        default: return nil
        }
    }

    static let `default` = HotkeyConfig()
}

struct AppConfig: Codable {
    var dictationHotkey: HotkeyConfig = .default
    var sttBackend: String = BackendOption.whisper.backend
    var sttModel: String = BackendOption.whisper.model
    var meetingSummaryBackend: String = MeetingSummaryBackendOption.openAI.backend
    var defaultMeetingTemplateID: String = MeetingTemplates.autoID
    var whisperModel: String = BackendOption.whisper.model
    var idleTimeout: Double = 120
    var autoRecordMeetings: Bool = false
    var showMeetingDetectionNotification: Bool = true
    var meetingRecordingSavePolicy: MeetingRecordingSavePolicy = .never
    var darkMode: Bool = true
    var enableDoubleTapDictation: Bool = true
    var launchAtLogin: Bool = false
    var openDashboardOnLaunch: Bool = true
    var showFloatingIndicator: Bool = true
    var dashboardWindowFrame: WindowFrame? = nil
    var indicatorOrigin: CGPointCodable? = nil
    var openAIAPIKey: String = ""
    var openRouterAPIKey: String = ""
    var openAIModel: String = ""
    var openRouterModel: String = ""
    var chatGPTModel: String = ""
    var summaryModel: String = ""
    var meetingSummaryModel: String = ""
    var hasCompletedOnboarding: Bool = false
    var userName: String = ""
    var customMeetingTemplates: [CustomMeetingTemplate] = []
    var customWords: [CustomWord] = [
        CustomWord(word: "muesli", replacement: "muesli"),
    ]
    var folderOrder: [Int64] = []
    var soundEnabled: Bool = true
    var recordingColorHex: String = "1e1e2e"   // Catppuccin Mocha base, without #
    var menuBarIcon: String = "muesli"
    var showNextMeetingInMenuBar: Bool = true
    var maraudersMapUnlocked: Bool = false
    var maraudersMapAudioClip: String = "bbc_world_news"
    var maraudersMapCustomAudioPath: String?
    var hiddenCalendarEventIDs: [String] = []
    var enablePostProcessor: Bool = false
    var activePostProcessorId: String = PostProcessorOption.finetunedV2.id
    var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt

    enum CodingKeys: String, CodingKey {
        case dictationHotkey = "dictation_hotkey"
        case sttBackend = "stt_backend"
        case sttModel = "stt_model"
        case meetingSummaryBackend = "meeting_summary_backend"
        case defaultMeetingTemplateID = "default_meeting_template_id"
        case whisperModel = "whisper_model"
        case idleTimeout = "idle_timeout"
        case autoRecordMeetings = "auto_record_meetings"
        case showMeetingDetectionNotification = "show_meeting_detection_notification"
        case meetingRecordingSavePolicy = "meeting_recording_save_policy"
        case darkMode = "dark_mode"
        case enableDoubleTapDictation = "enable_double_tap_dictation"
        case launchAtLogin = "launch_at_login"
        case openDashboardOnLaunch = "open_dashboard_on_launch"
        case showFloatingIndicator = "show_floating_indicator"
        case dashboardWindowFrame = "dashboard_window_frame"
        case indicatorOrigin = "indicator_origin"
        case openAIAPIKey = "openai_api_key"
        case openRouterAPIKey = "openrouter_api_key"
        case openAIModel = "openai_model"
        case openRouterModel = "openrouter_model"
        case chatGPTModel = "chatgpt_model"
        case summaryModel = "summary_model"
        case meetingSummaryModel = "meeting_summary_model"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case userName = "user_name"
        case customMeetingTemplates = "custom_meeting_templates"
        case customWords = "custom_words"
        case folderOrder = "folder_order"
        case soundEnabled = "sound_enabled"
        case recordingColorHex = "recording_color_hex"
        case menuBarIcon = "menu_bar_icon"
        case showNextMeetingInMenuBar = "show_next_meeting_in_menu_bar"
        case maraudersMapUnlocked = "marauders_map_unlocked"
        case maraudersMapAudioClip = "marauders_map_audio_clip"
        case maraudersMapCustomAudioPath = "marauders_map_custom_audio_path"
        case hiddenCalendarEventIDs = "hidden_calendar_event_ids"
        case enablePostProcessor = "enable_post_processor"
        case activePostProcessorId = "active_post_processor_id"
        case postProcessorSystemPrompt = "post_processor_system_prompt"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        dictationHotkey = (try? c.decode(HotkeyConfig.self, forKey: .dictationHotkey)) ?? defaults.dictationHotkey
        sttBackend = (try? c.decode(String.self, forKey: .sttBackend)) ?? defaults.sttBackend
        sttModel = (try? c.decode(String.self, forKey: .sttModel)) ?? defaults.sttModel
        meetingSummaryBackend = (try? c.decode(String.self, forKey: .meetingSummaryBackend)) ?? defaults.meetingSummaryBackend
        defaultMeetingTemplateID = (try? c.decode(String.self, forKey: .defaultMeetingTemplateID)) ?? defaults.defaultMeetingTemplateID
        whisperModel = (try? c.decode(String.self, forKey: .whisperModel)) ?? defaults.whisperModel
        idleTimeout = (try? c.decode(Double.self, forKey: .idleTimeout)) ?? defaults.idleTimeout
        autoRecordMeetings = (try? c.decode(Bool.self, forKey: .autoRecordMeetings)) ?? defaults.autoRecordMeetings
        showMeetingDetectionNotification = (try? c.decode(Bool.self, forKey: .showMeetingDetectionNotification)) ?? defaults.showMeetingDetectionNotification
        meetingRecordingSavePolicy = (try? c.decode(MeetingRecordingSavePolicy.self, forKey: .meetingRecordingSavePolicy)) ?? defaults.meetingRecordingSavePolicy
        darkMode = (try? c.decode(Bool.self, forKey: .darkMode)) ?? defaults.darkMode
        enableDoubleTapDictation = (try? c.decode(Bool.self, forKey: .enableDoubleTapDictation)) ?? defaults.enableDoubleTapDictation
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        openDashboardOnLaunch = (try? c.decode(Bool.self, forKey: .openDashboardOnLaunch)) ?? defaults.openDashboardOnLaunch
        showFloatingIndicator = (try? c.decode(Bool.self, forKey: .showFloatingIndicator)) ?? defaults.showFloatingIndicator
        dashboardWindowFrame = try? c.decode(WindowFrame.self, forKey: .dashboardWindowFrame)
        indicatorOrigin = try? c.decode(CGPointCodable.self, forKey: .indicatorOrigin)
        openAIAPIKey = (try? c.decode(String.self, forKey: .openAIAPIKey)) ?? defaults.openAIAPIKey
        openRouterAPIKey = (try? c.decode(String.self, forKey: .openRouterAPIKey)) ?? defaults.openRouterAPIKey
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
        openRouterModel = (try? c.decode(String.self, forKey: .openRouterModel)) ?? defaults.openRouterModel
        chatGPTModel = (try? c.decode(String.self, forKey: .chatGPTModel)) ?? defaults.chatGPTModel
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? defaults.summaryModel
        meetingSummaryModel = (try? c.decode(String.self, forKey: .meetingSummaryModel)) ?? defaults.meetingSummaryModel
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? defaults.hasCompletedOnboarding
        userName = (try? c.decode(String.self, forKey: .userName)) ?? defaults.userName
        customMeetingTemplates = (try? c.decode([CustomMeetingTemplate].self, forKey: .customMeetingTemplates)) ?? defaults.customMeetingTemplates
        customWords = (try? c.decode([CustomWord].self, forKey: .customWords)) ?? defaults.customWords
        folderOrder = (try? c.decode([Int64].self, forKey: .folderOrder)) ?? defaults.folderOrder
        soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? defaults.soundEnabled
        recordingColorHex = (try? c.decode(String.self, forKey: .recordingColorHex)) ?? defaults.recordingColorHex
        menuBarIcon = (try? c.decode(String.self, forKey: .menuBarIcon)) ?? defaults.menuBarIcon
        showNextMeetingInMenuBar = (try? c.decode(Bool.self, forKey: .showNextMeetingInMenuBar)) ?? defaults.showNextMeetingInMenuBar
        maraudersMapUnlocked = (try? c.decode(Bool.self, forKey: .maraudersMapUnlocked)) ?? defaults.maraudersMapUnlocked
        maraudersMapAudioClip = (try? c.decode(String.self, forKey: .maraudersMapAudioClip)) ?? defaults.maraudersMapAudioClip
        maraudersMapCustomAudioPath = try? c.decode(String.self, forKey: .maraudersMapCustomAudioPath)
        hiddenCalendarEventIDs = (try? c.decode([String].self, forKey: .hiddenCalendarEventIDs)) ?? defaults.hiddenCalendarEventIDs
        enablePostProcessor = (try? c.decode(Bool.self, forKey: .enablePostProcessor)) ?? defaults.enablePostProcessor
        activePostProcessorId = (try? c.decode(String.self, forKey: .activePostProcessorId)) ?? defaults.activePostProcessorId
        postProcessorSystemPrompt = (try? c.decode(String.self, forKey: .postProcessorSystemPrompt)) ?? defaults.postProcessorSystemPrompt
    }
}

struct WindowFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct CGPointCodable: Codable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var arrayContainer = try? decoder.unkeyedContainer() {
            let x = try arrayContainer.decode(Double.self)
            let y = try arrayContainer.decode(Double.self)
            self.init(x: x, y: y)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }

    enum CodingKeys: String, CodingKey {
        case x, y
    }
}

enum DictationState: String {
    case idle
    case preparing
    case recording
    case transcribing
}
