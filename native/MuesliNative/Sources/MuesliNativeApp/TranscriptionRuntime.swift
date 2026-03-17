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

    func preload(backend: BackendOption, progress: ((Double, String?) -> Void)? = nil) async {
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
        default:
            fputs("[muesli-native] unknown backend: \(backend.backend)\n", stderr)
        }
    }

    func transcribeDictation(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        var result = try await route(url: url, backend: backend)
        result = removeFillers(result)
        return applyCustomWords(result, customWords: customWords)
    }

    func transcribeMeeting(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        var result = try await route(url: url, backend: backend)
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

    func shutdown() {
        Task {
            await fluidTranscriber.shutdown()
            await whisperTranscriber.shutdown()
            if #available(macOS 15, *) {
                await nemotronTranscriber.shutdown()
                await qwen3Transcriber.shutdown()
            }
        }
    }

    private func removeFillers(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = FillerWordFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: result.segments)
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
