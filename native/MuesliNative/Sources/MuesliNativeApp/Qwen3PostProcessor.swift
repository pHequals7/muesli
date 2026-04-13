import Foundation
import LLM

enum Qwen3PostProcessorLogging {
    private static let verboseEnv = "MUESLI_DEBUG_POSTPROC_LOGS"
    private static let pairLogEnv = "MUESLI_LOG_POSTPROC_PAIRS"

    static var isVerboseEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[verboseEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static var isPairLoggingEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[pairLogEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func log(_ message: String) {
        fputs("[muesli-native] \(message)\n", stderr)
    }

    static func logVerbose(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        log(message())
    }
}

enum Qwen3DeletionCueDetector {
    private static let deletionCues: [String] = [
        "scratch that", "delete that", "forget that", "never mind",
    ]

    static func containsDeletionCue(_ text: String) -> Bool {
        let lower = text.lowercased()
        return deletionCues.contains { lower.contains($0) }
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
            of: #"(?is)<think\b[^>]*>[\s\S]*$"#,
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
            of: #"(?im)^\s*when the speaker is dictating a numbered list or bullet list,\s*format each item on its own line\.?\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*if the speaker is dictating a list, such as saying ["“”]?first point["“”]?[,]?\s*["“”]?second point["“”]?[,]?\s*or ["“”]?bullet point["“”]?[,]?\s*format each item on its own line\.?\s*"#,
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

    static func shouldFallbackToInput(cleaned: String, input: String) -> Bool {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lower = trimmed.lowercased()
        let assistantMarkers = [
            "the user is asking",
            "**analysis:**",
            "analysis:",
            "**action plan:**",
            "action plan:",
            "grammar/spelling:",
            "meaning:",
            "remove the filler word",
        ]
        if assistantMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let inputLength = max(input.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        return trimmed.count > inputLength * 4 && trimmed.count > 500
    }
}

enum Qwen3PostProcessorConfig {
    // Dev/Canary override — takes precedence over the UI-selected model when set.
    static let envOverride = "MUESLI_QWEN3_POSTPROC_GGUF"
    static let legacyDirectoryEnvOverride = "MUESLI_QWEN3_POSTPROC_DIR"
    static let maxContextTokens: Int32 = 768

    static func formatInput(_ text: String) -> String {
        """
        <USER-INPUT>
        \(text)
        </USER-INPUT>
        """
    }

    /// Checks for a dev/Canary env-var override and returns the resolved GGUF URL if present.
    static func devOverrideURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        for key in [envOverride, legacyDirectoryEnvOverride] {
            guard let raw = env[key], !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let found = firstGGUF(in: url) { return found }
            } else if url.pathExtension.lowercased() == "gguf" {
                return url
            }
        }
        return nil
    }

    private static func firstGGUF(in directory: URL) -> URL? {
        guard let e = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let f as URL in e where f.pathExtension.lowercased() == "gguf" { return f }
        return nil
    }
}

@available(macOS 15, *)
private actor Qwen3PostProcessorManager {
    private let modelURL: URL
    private let systemPrompt: String
    private var bot: LLM?

    init(modelURL: URL, systemPrompt: String) {
        self.modelURL = modelURL
        self.systemPrompt = systemPrompt
    }

    func warm() throws {
        _ = try loadBot()
    }

    func process(_ text: String) async throws -> String {
        let bot = try loadBot()
        defer { bot.reset() }
        let formattedInput = Qwen3PostProcessorConfig.formatInput(text)
        await bot.respond(to: formattedInput, thinking: .suppressed)
        let raw = bot.output
        let cleaned = Qwen3PostProcessorOutputCleaner.clean(raw)
        Qwen3PostProcessorLogging.log("Qwen3 GGUF prompt chars=\(bot.preprocess(formattedInput, [], .suppressed).count)")
        Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF raw output: \(raw)")
        Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF cleaned output: \(cleaned)")
        if Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: cleaned, input: text) {
            Qwen3PostProcessorLogging.log("Qwen3 GGUF output rejected; falling back to raw ASR transcript")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private func loadBot() throws -> LLM {
        if let bot { return bot }
        guard let loaded = LLM(
            from: modelURL,
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
        loaded.useResolvedTemplate(systemPrompt: systemPrompt)
        bot = loaded
        return loaded
    }
}

@available(macOS 15, *)
actor Qwen3PostProcessor {
    private var modelURL: URL
    private var systemPrompt: String
    private var manager: Qwen3PostProcessorManager?
    private var loadTask: Task<Qwen3PostProcessorManager, Error>?

    init(modelURL: URL, systemPrompt: String) {
        // Dev/Canary env-var override takes precedence.
        self.modelURL = Qwen3PostProcessorConfig.devOverrideURL() ?? modelURL
        self.systemPrompt = systemPrompt
    }

    /// Swap to a different model or system prompt. Discards the loaded manager so
    /// the next `prepare()` or `process()` call reloads with the new config.
    func reconfigure(modelURL: URL, systemPrompt: String) {
        let resolved = Qwen3PostProcessorConfig.devOverrideURL() ?? modelURL
        guard resolved != self.modelURL || systemPrompt != self.systemPrompt else { return }
        self.modelURL = resolved
        self.systemPrompt = systemPrompt
        manager = nil
        loadTask?.cancel()
        loadTask = nil
    }

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
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let url = self.modelURL
        let prompt = self.systemPrompt
        let task = Task<Qwen3PostProcessorManager, Error> {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "Qwen3PostProcessor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Post-processor model not found at \(url.path). Download it from the Models tab.",
                ])
            }
            let manager = Qwen3PostProcessorManager(modelURL: url, systemPrompt: prompt)
            try await manager.warm()
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
