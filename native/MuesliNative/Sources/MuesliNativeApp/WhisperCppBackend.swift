import Foundation
import WhisperKit
import MuesliCore

/// Native Swift transcription backend using WhisperKit (CoreML on ANE/GPU).
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "WhisperKit model not loaded."
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }

    /// Load a WhisperKit CoreML model. Downloads from HuggingFace if not cached.
    func loadModel(modelName: String, progress: ((Double, String?) -> Void)? = nil) async throws {
        if loadedModel == modelName, whisperKit != nil { return }

        fputs("[whisperkit] loading model: \(modelName)...\n", stderr)
        progress?(0.1, "Preparing \(modelName)...")

        let config = WhisperKitConfig(
            model: modelName,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )

        progress?(0.5, "Loading \(modelName)...")
        whisperKit = try await WhisperKit(config)
        loadedModel = modelName
        fputs("[whisperkit] model ready: \(modelName)\n", stderr)
        progress?(1.0, nil)
    }

    /// Transcribe a 16kHz mono WAV file.
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        let start = CFAbsoluteTimeGetCurrent()
        let results = try await whisperKit.transcribe(audioPath: wavURL.path)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text: text, processingTime: elapsed)
    }

    /// Run a short silent transcription to trigger CoreML compilation.
    /// First-run compilation takes 10-30s; subsequent loads are instant.
    func warmup() async throws {
        guard let whisperKit else { return }
        let silence = [Float](repeating: 0, count: 16000) // 1 second of silence at 16kHz
        let start = CFAbsoluteTimeGetCurrent()
        let _: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: silence)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        fputs("[whisperkit] warmup transcription took \(String(format: "%.1f", elapsed))s\n", stderr)
    }

    func shutdown() {
        whisperKit = nil
        loadedModel = nil
    }

    // MARK: - Model Storage

    /// WhisperKit stores models under ~/Documents/huggingface/ by default.
    /// Check if a model variant directory exists.
    static func isModelDownloaded(_ modelName: String) -> Bool {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        // WhisperKit uses snapshot directories — check if any snapshot contains our model folder
        guard let snapshots = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return false
        }
        let fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        for snapshot in snapshots {
            let modelDir = snapshot.appendingPathComponent(fullName)
            if fm.fileExists(atPath: modelDir.path) {
                return true
            }
        }
        return false
    }

    /// Delete cached model files for a WhisperKit model variant.
    static func deleteModel(_ modelName: String) {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        guard let snapshots = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return
        }
        let fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        for snapshot in snapshots {
            let modelDir = snapshot.appendingPathComponent(fullName)
            try? fm.removeItem(at: modelDir)
        }
    }
}
