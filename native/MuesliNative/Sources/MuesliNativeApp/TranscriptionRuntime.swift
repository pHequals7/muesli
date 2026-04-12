import FluidAudio
import Foundation
import MuesliCore

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

actor TranscriptionCoordinator {
    private let fluidTranscriber = FluidAudioTranscriber()
    private let whisperTranscriber = WhisperCppTranscriber()
    private var _nemotronTranscriber: Any?
    private var _qwen3Transcriber: Any?
    private var _qwen3PostProcessor: Any?
    private var _canaryQwenTranscriber: Any?
    private var _cohereTranscriber: Any?
    private var vadManager: VadManager?
    private var diarizerManager: DiarizerManager?
    private var activeBackend: String?

    @available(macOS 15, *)
    private var nemotronTranscriber: NemotronStreamingTranscriber {
        if _nemotronTranscriber == nil {
            _nemotronTranscriber = NemotronStreamingTranscriber()
        }
        return _nemotronTranscriber as! NemotronStreamingTranscriber
    }

    /// Public accessor for streaming dictation — triggers lazy init if needed.
    @available(macOS 15, *)
    func getNemotronTranscriber() -> NemotronStreamingTranscriber {
        return nemotronTranscriber
    }

    @available(macOS 15, *)
    private var qwen3Transcriber: Qwen3AsrTranscriber {
        if _qwen3Transcriber == nil {
            _qwen3Transcriber = Qwen3AsrTranscriber()
        }
        return _qwen3Transcriber as! Qwen3AsrTranscriber
    }

    @available(macOS 15, *)
    private var canaryQwenTranscriber: CanaryQwenTranscriber {
        if _canaryQwenTranscriber == nil {
            _canaryQwenTranscriber = CanaryQwenTranscriber()
        }
        return _canaryQwenTranscriber as! CanaryQwenTranscriber
    }

    private var postProcessorModelURL: URL = PostProcessorOption.finetunedV2.modelURL
    private var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt

    @available(macOS 15, *)
    private var qwen3PostProcessor: Qwen3PostProcessor {
        if _qwen3PostProcessor == nil {
            _qwen3PostProcessor = Qwen3PostProcessor(
                modelURL: postProcessorModelURL,
                systemPrompt: postProcessorSystemPrompt
            )
        }
        return _qwen3PostProcessor as! Qwen3PostProcessor
    }

    @available(macOS 15, *)
    func setActivePostProcessor(option: PostProcessorOption, systemPrompt: String) async {
        postProcessorModelURL = option.modelURL
        postProcessorSystemPrompt = systemPrompt
        if let existing = _qwen3PostProcessor as? Qwen3PostProcessor {
            await existing.reconfigure(modelURL: option.modelURL, systemPrompt: systemPrompt)
        }
    }

    @available(macOS 15, *)
    private var cohereTranscriber: CohereTranscribeTranscriber {
        if _cohereTranscriber == nil {
            _cohereTranscriber = CohereTranscribeTranscriber()
        }
        return _cohereTranscriber as! CohereTranscribeTranscriber
    }

    func preload(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        progress: ((Double, String?) -> Void)? = nil
    ) async {
        activeBackend = backend.backend

        // Initialize Silero VAD for meeting chunk silence detection
        if vadManager == nil {
            do {
                vadManager = try await VadManager()
                fputs("[muesli-native] Silero VAD loaded\n", stderr)
            } catch {
                fputs("[muesli-native] VAD load failed (non-critical): \(error)\n", stderr)
            }
        }

        // Initialize speaker diarization (lazy — model downloads on first use)
        if diarizerManager == nil {
            do {
                let diarizer = DiarizerManager()
                let models = try await DiarizerModels.download()
                diarizer.initialize(models: models)
                diarizerManager = diarizer
                fputs("[muesli-native] Speaker diarization loaded\n", stderr)
            } catch {
                fputs("[muesli-native] Diarization load failed (non-critical): \(error)\n", stderr)
            }
        }

        switch backend.backend {
        case "fluidaudio":
            let version: AsrModelVersion = backend.model.contains("v2") ? .v2 : .v3
            do {
                try await fluidTranscriber.loadModels(version: version, progress: progress)
            } catch {
                fputs("[muesli-native] FluidAudio preload failed: \(error)\n", stderr)
            }
        case "whisper":
            do {
                try await whisperTranscriber.loadModel(modelName: backend.model, progress: progress)
            } catch {
                fputs("[muesli-native] whisper.cpp preload failed: \(error)\n", stderr)
            }
        case "nemotron":
            if #available(macOS 15, *) {
                do {
                    try await nemotronTranscriber.loadModels(progress: progress)
                    // Warmup ANE so first dictation starts instantly
                    fputs("[muesli-native] Nemotron warmup: running silent chunk for ANE compilation...\n", stderr)
                    var state = try await nemotronTranscriber.makeStreamState()
                    let silence = [Float](repeating: 0, count: 8960)
                    _ = try? await nemotronTranscriber.transcribeChunk(samples: silence, state: &state)
                    fputs("[muesli-native] Nemotron warmup complete\n", stderr)
                } catch {
                    fputs("[muesli-native] Nemotron preload failed: \(error)\n", stderr)
                }
            } else {
                fputs("[muesli-native] Nemotron requires macOS 15+\n", stderr)
            }
        case "qwen":
            if #available(macOS 15, *) {
                do {
                    try await qwen3Transcriber.loadModels(progress: progress)
                } catch {
                    fputs("[muesli-native] Qwen3 ASR preload failed: \(error)\n", stderr)
                }
            } else {
                fputs("[muesli-native] Qwen3 ASR requires macOS 15+\n", stderr)
            }
        case "canary":
            if #available(macOS 15, *) {
                do {
                    try await canaryQwenTranscriber.prepare(progress: progress)
                } catch {
                    fputs("[muesli-native] Canary Qwen preload failed: \(error)\n", stderr)
                }
            } else {
                fputs("[muesli-native] Canary Qwen requires macOS 15+\n", stderr)
            }
        case "cohere":
            if #available(macOS 15, *) {
                do {
                    try await cohereTranscriber.prepare(progress: progress)
                } catch {
                    fputs("[muesli-native] Cohere Transcribe preload failed: \(error)\n", stderr)
                }
            } else {
                fputs("[muesli-native] Cohere Transcribe requires macOS 15+\n", stderr)
            }
        default:
            fputs("[muesli-native] unknown backend: \(backend.backend)\n", stderr)
        }

        await preloadPostProcessorIfNeeded(enabled: enablePostProcessor)
    }

    func preloadPostProcessorIfNeeded(enabled: Bool) async {
        if enabled, #available(macOS 15, *) {
            do {
                try await qwen3PostProcessor.prepare()
            } catch {
                fputs("[muesli-native] Qwen3 post-processor preload failed: \(error)\n", stderr)
            }
        }
    }

    func transcribeDictation(
        at url: URL,
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        customWords: [[String: Any]] = []
    ) async throws -> SpeechTranscriptionResult {
        // Cohere decodes hallucinated text from silence — skip if VAD detects no speech
        if backend.backend == "cohere", let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: dictation is silent, skipping Cohere transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        var result = try await route(url: url, backend: backend)
        result = removeArtifacts(result)
        if !result.text.isEmpty {
            fputs("[muesli-native] Dictation raw transcript after artifact cleanup: \(result.text)\n", stderr)
        }
        result = try await postProcessDictationIfNeeded(
            result,
            backend: backend,
            enabled: enablePostProcessor
        ) ?? removeFillersWithLogging(result)
        let final = applyCustomWords(result, customWords: customWords)
        if !final.text.isEmpty {
            fputs("[muesli-native] Dictation final transcript: \(final.text)\n", stderr)
        }
        return final
    }

    func transcribeMeeting(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        var result = try await route(url: url, backend: backend)
        result = removeArtifacts(result)
        result = removeFillers(result)
        return applyCustomWords(result, customWords: customWords)
    }

    func transcribeMeetingChunk(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        // Run VAD to skip silent chunks (prevents hallucinations)
        if let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: chunk is silent, skipping transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        var result = try await route(url: url, backend: backend)
        result = removeArtifacts(result)
        result = removeFillers(result)
        return applyCustomWords(result, customWords: customWords)
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? {
        guard let diarizerManager, diarizerManager.isAvailable else {
            fputs("[muesli-native] diarization not available, skipping\n", stderr)
            return nil
        }
        fputs("[muesli-native] running speaker diarization on system audio...\n", stderr)
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let result = try diarizerManager.performCompleteDiarization(samples, sampleRate: 16000)
        let speakerCount = Set(result.segments.map(\.speakerId)).count
        fputs("[muesli-native] diarization complete: \(result.segments.count) segments, \(speakerCount) speakers\n", stderr)
        return result
    }

    func getVadManager() -> VadManager? {
        vadManager
    }

    func getDiarizerManager() -> DiarizerManager? {
        diarizerManager
    }

    func shutdown() {
        Task {
            await fluidTranscriber.shutdown()
            await whisperTranscriber.shutdown()
            if #available(macOS 15, *) {
                await nemotronTranscriber.shutdown()
                await qwen3Transcriber.shutdown()
                await qwen3PostProcessor.shutdown()
                await canaryQwenTranscriber.shutdown()
                await cohereTranscriber.shutdown()
            }
        }
    }

    private func removeFillers(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = FillerWordFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: result.segments)
    }

    private func removeFillersWithLogging(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()
        let filtered = removeFillers(result)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if filtered.text != result.text {
            fputs("[muesli-native] FillerWordFilter applied in \(String(format: "%.1f", elapsedMs))ms -> \(filtered.text)\n", stderr)
        } else {
            fputs("[muesli-native] FillerWordFilter skipped effective changes (\(String(format: "%.1f", elapsedMs))ms)\n", stderr)
        }
        return filtered
    }

    private func removeArtifacts(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = TranscriptionEngineArtifactsFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: filtered.isEmpty ? [] : result.segments)
    }

    private func postProcessDictationIfNeeded(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        enabled: Bool
    ) async throws -> SpeechTranscriptionResult? {
        guard enabled else {
            fputs("[muesli-native] Qwen3 post-processor disabled for dictation\n", stderr)
            return nil
        }
        guard !result.text.isEmpty else {
            fputs("[muesli-native] Qwen3 post-processor skipped: empty transcript\n", stderr)
            return nil
        }
        guard #available(macOS 15, *) else {
            fputs("[muesli-native] Qwen3 post-processor skipped: requires macOS 15+\n", stderr)
            return nil
        }

        do {
            // Prototype mode intentionally runs cleanup on every dictation while the toggle is on.
            // Keep the heuristics in place for a future smart-mode gate once prompt/model behavior stabilizes.
            fputs("[muesli-native] Qwen3 post-processor forced by toggle (prototype mode)\n", stderr)
            let start = CFAbsoluteTimeGetCurrent()
            let processed = try await qwen3PostProcessor.process(result.text)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3PostProcessingHeuristics.containsDeletionCue(result.text) {
                fputs("[muesli-native] Qwen3 post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back\n", stderr)
                return nil
            }
            fputs("[muesli-native] Qwen3 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))\n", stderr)
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor final output: \(trimmed)")
            return SpeechTranscriptionResult(
                text: trimmed,
                segments: trimmed.isEmpty ? [] : result.segments
            )
        } catch {
            fputs("[muesli-native] Qwen3 post-processor failed, falling back: \(error)\n", stderr)
            return nil
        }
    }

    private func applyCustomWords(_ result: SpeechTranscriptionResult, customWords: [[String: Any]]) -> SpeechTranscriptionResult {
        guard !customWords.isEmpty, !result.text.isEmpty else { return result }
        let entries = customWords.compactMap { dict -> CustomWord? in
            guard let word = dict["word"] as? String else { return nil }
            return CustomWord(word: word, replacement: dict["replacement"] as? String)
        }
        guard !entries.isEmpty else { return result }
        let correctedText = CustomWordMatcher.apply(text: result.text, customWords: entries)
        return SpeechTranscriptionResult(text: correctedText, segments: result.segments)
    }

    private func route(url: URL, backend: BackendOption) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            return try await transcribeWithWhisperCpp(url: url)
        case "nemotron":
            return try await transcribeWithNemotron(url: url)
        case "qwen":
            return try await transcribeWithQwen3(url: url)
        case "canary":
            return try await transcribeWithCanaryQwen(url: url)
        case "cohere":
            return try await transcribeWithCohere(url: url)
        default:
            return try await transcribeWithFluidAudio(url: url)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] FluidAudio result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = (result.tokenTimings ?? []).map { timing in
            SpeechSegment(start: timing.startTime, end: timing.endTime, text: timing.token)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: segments.isEmpty && !text.isEmpty ? [SpeechSegment(start: 0, end: result.duration, text: text)] : segments
        )
    }

    // MARK: - whisper.cpp (Whisper on Metal/CPU)

    private func transcribeWithWhisperCpp(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with whisper.cpp: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] whisper.cpp result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Qwen3 ASR (Autoregressive CoreML on ANE)

    private func transcribeWithQwen3(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Qwen3 ASR: \(url.lastPathComponent)\n", stderr)
            let result = try await qwen3Transcriber.transcribe(wavURL: url)
            fputs("[muesli-native] Qwen3 ASR result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
            ])
        }
    }

    private func transcribeWithCanaryQwen(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Canary Qwen: \(url.lastPathComponent)\n", stderr)
            let result = try await canaryQwenTranscriber.transcribe(wavURL: url)
            fputs("[muesli-native] Canary Qwen result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            CanaryProfilingLog.write("[muesli-native] Canary Qwen profile: \(result.profile.logDescription(prefix: "profile"))")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Canary Qwen requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Cohere Transcribe (CoreML)

    private func transcribeWithCohere(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Cohere Transcribe: \(url.lastPathComponent)\n", stderr)
            let result = try await cohereTranscriber.transcribe(wavURL: url)
            fputs("[muesli-native] Cohere Transcribe result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Nemotron Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Nemotron: \(url.lastPathComponent)\n", stderr)
            let result = try await nemotronTranscriber.transcribe(wavURL: url)
            fputs("[muesli-native] Nemotron result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron requires macOS 15 or later.",
            ])
        }
    }

}
