import Foundation
import LLM

enum Qwen3PostProcessingHeuristics {
    private static let formattingCues: [String] = [
        "bullet point", "bullet points", "number one", "number two", "number three",
        "new paragraph", "new line", "next line", "comma", "period", "full stop",
        "question mark", "exclamation point", "colon", "semicolon", "open quote",
        "close quote", "open parenthesis", "close parenthesis",
    ]

    private static let deletionCues: [String] = [
        "scratch that", "delete that", "forget that", "never mind",
    ]

    static func shouldApply(to text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if FillerWordFilter.apply(trimmed) != trimmed { return true }
        return containsDeletionCue(trimmed) || containsFormattingCue(trimmed)
    }

    static func triggerLabels(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var labels: [String] = []
        if FillerWordFilter.apply(trimmed) != trimmed {
            labels.append("fillers")
        }
        if containsDeletionCue(trimmed) {
            labels.append("deletion")
        }
        if containsFormattingCue(trimmed) {
            labels.append("formatting")
        }
        return labels
    }

    static func containsDeletionCue(_ text: String) -> Bool {
        containsPhrase(in: text, phrases: deletionCues)
    }

    static func containsFormattingCue(_ text: String) -> Bool {
        containsPhrase(in: text, phrases: formattingCues)
    }

    private static func containsPhrase(in text: String, phrases: [String]) -> Bool {
        let lower = text.lowercased()
        return phrases.contains { lower.contains($0) }
    }
}

enum Qwen3PostProcessorOutputCleaner {
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        result = result.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<\|im_(?:start|end)\|>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```[A-Za-z0-9_-]*\s*"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^`+|`+$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[end of text\]"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:[#>*-]+\s*)?(?:\*\*|__)?(?:transcription|cleaned transcription|output|response)(?:\*\*|__)?\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:\*\*|__)([^*\n_]{1,80})(?:\*\*|__)\s*$"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum Qwen3PostProcessorConfig {
    static let envOverride = "MUESLI_QWEN3_POSTPROC_GGUF"
    static let legacyDirectoryEnvOverride = "MUESLI_QWEN3_POSTPROC_DIR"
    static let maxContextTokens: Int32 = 2048

    static let systemPrompt = """
    Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.

    You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.

    Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
    """

    static let defaultCacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/muesli/models/qwen3-postproc-gguf", isDirectory: true)
}

private enum Qwen3PostProcessorModelStore {
    static func resolvedModelURL() throws -> URL {
        if let override = overrideModelURL() {
            return override
        }
        if let cached = ggufURL(in: Qwen3PostProcessorConfig.defaultCacheDirectory) {
            return cached
        }
        throw NSError(domain: "Qwen3PostProcessor", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Qwen3 post-processor GGUF not found. Set \(Qwen3PostProcessorConfig.envOverride) to a .gguf file or directory.",
        ])
    }

    private static func overrideModelURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env[Qwen3PostProcessorConfig.envOverride], !raw.isEmpty {
            return resolveOverride(raw)
        }
        if let raw = env[Qwen3PostProcessorConfig.legacyDirectoryEnvOverride], !raw.isEmpty {
            return resolveOverride(raw)
        }
        return nil
    }

    private static func resolveOverride(_ raw: String) -> URL? {
        let url = URL(fileURLWithPath: raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return ggufURL(in: url)
        }
        return url.pathExtension.lowercased() == "gguf" ? url : nil
    }

    private static func ggufURL(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "gguf" else { continue }
            return fileURL
        }
        return nil
    }
}

@available(macOS 15, *)
private final class Qwen3PostProcessorManager {
    private let modelURL: URL
    private let template = Template.chatML(Qwen3PostProcessorConfig.systemPrompt)

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func warm() throws {
        _ = try makeBot()
    }

    func process(_ text: String) async throws -> String {
        let bot = try makeBot()
        let prompt = bot.preprocess(text, [], .suppressed)
        let raw = await bot.getCompletion(from: prompt)
        let cleaned = Qwen3PostProcessorOutputCleaner.clean(raw)
        fputs("[muesli-native] Qwen3 GGUF prompt chars=\(prompt.count)\n", stderr)
        fputs("[muesli-native] Qwen3 GGUF raw output: \(raw)\n", stderr)
        fputs("[muesli-native] Qwen3 GGUF cleaned output: \(cleaned)\n", stderr)
        return cleaned
    }

    private func makeBot() throws -> LLM {
        guard let bot = LLM(
            from: modelURL,
            template: template,
            seed: 7,
            topK: 1,
            topP: 1.0,
            temp: 0.0,
            repeatPenalty: 1.0,
            repetitionLookback: 64,
            historyLimit: 0,
            maxTokenCount: Qwen3PostProcessorConfig.maxContextTokens
        ) else {
            throw NSError(domain: "Qwen3PostProcessor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load Qwen3 GGUF model at \(modelURL.path)",
            ])
        }
        return bot
    }
}

@available(macOS 15, *)
actor Qwen3PostProcessor {
    private var manager: Qwen3PostProcessorManager?
    private var loadTask: Task<Qwen3PostProcessorManager, Error>?

    func prepare() async throws {
        _ = try await loadManager()
    }

    func process(_ text: String) async throws -> String {
        let manager = try await loadManager()
        return try await manager.process(text)
    }

    func shutdown() {
        manager = nil
        loadTask?.cancel()
        loadTask = nil
    }

    private func loadManager() async throws -> Qwen3PostProcessorManager {
        if let manager {
            return manager
        }
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task<Qwen3PostProcessorManager, Error> {
            let modelURL = try Qwen3PostProcessorModelStore.resolvedModelURL()
            let manager = Qwen3PostProcessorManager(modelURL: modelURL)
            try manager.warm()
            return manager
        }
        loadTask = task
        do {
            let loaded = try await task.value
            manager = loaded
            loadTask = nil
            return loaded
        } catch {
            loadTask = nil
            throw error
        }
    }
}
