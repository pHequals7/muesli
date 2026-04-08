import Foundation
import SwiftWhisper
import MuesliCore

/// Native Swift transcription backend using whisper.cpp via SwiftWhisper.
/// Runs Whisper models on CPU + Metal GPU.
actor WhisperCppTranscriber {
    private var whisper: Whisper?
    private var loadedModelPath: String?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case modelDownloadFailed(String)
        case audioLoadFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Whisper model not loaded."
            case .modelDownloadFailed(let msg): return "Model download failed: \(msg)"
            case .audioLoadFailed(let msg): return "Audio load failed: \(msg)"
            }
        }
    }

    /// Load a ggml model file. Downloads from HuggingFace if not cached.
    func loadModel(modelName: String, progress: ((Double, String?) -> Void)? = nil) async throws {
        let modelPath = try await ensureModelDownloaded(modelName: modelName, progress: progress)
        if loadedModelPath == modelPath, whisper != nil { return }

        // Validate file size — ggml models are at least 10MB
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? Int) ?? 0
        if fileSize < 10_000_000 {
            // Corrupted/incomplete download — delete and throw
            try? FileManager.default.removeItem(atPath: modelPath)
            throw TranscriberError.modelDownloadFailed("Downloaded file is too small (\(fileSize) bytes), likely corrupted. Deleted — try again.")
        }

        fputs("[whisper.cpp] loading model: \(modelName) (\(fileSize / 1_000_000)MB)...\n", stderr)
        progress?(0.95, "Loading model...")
        let modelURL = URL(fileURLWithPath: modelPath)
        whisper = Whisper(fromFileURL: modelURL)
        loadedModelPath = modelPath
        fputs("[whisper.cpp] model ready\n", stderr)
    }

    /// Transcribe a 16kHz mono WAV file.
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let whisper else { throw TranscriberError.notLoaded }

        let audioFrames = try loadWavAsFloats(url: wavURL)
        let start = CFAbsoluteTimeGetCurrent()
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (text: text, processingTime: elapsed)
    }

    func shutdown() {
        whisper = nil
        loadedModelPath = nil
    }

    // MARK: - Model Download

    private static let modelsDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let modelURLs: [String: String] = [
        "ggml-small.en": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
        "ggml-small.en-q5_1": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin",
        "ggml-medium.en": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin",
        "ggml-large-v3-turbo": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        "ggml-large-v3-turbo-q5_0": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
    ]

    private func ensureModelDownloaded(modelName: String, progress: ((Double, String?) -> Void)? = nil) async throws -> String {
        let filename = modelName.hasSuffix(".bin") ? modelName : "\(modelName).bin"
        let localPath = Self.modelsDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: localPath.path) {
            return localPath.path
        }

        guard let urlString = Self.modelURLs[modelName.replacingOccurrences(of: ".bin", with: "")],
              let url = URL(string: urlString) else {
            throw TranscriberError.modelDownloadFailed("Unknown model: \(modelName)")
        }

        fputs("[whisper.cpp] downloading \(modelName) from HuggingFace...\n", stderr)
        progress?(0.0, "Downloading \(modelName)...")

        let delegate = DownloadProgressDelegate { fraction in
            progress?(fraction * 0.9, "Downloading \(modelName)...")  // Reserve 10% for loading
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        try await downloadWithRetry(from: url, to: localPath, session: session)
        fputs("[whisper.cpp] download complete: \(localPath.path)\n", stderr)
        return localPath.path
    }

    // MARK: - Audio Loading

    private func loadWavAsFloats(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        // Skip 44-byte WAV header, read 16-bit PCM samples
        guard data.count > 44 else {
            throw TranscriberError.audioLoadFailed("WAV file too small")
        }

        let pcmData = data.dropFirst(44)
        let sampleCount = pcmData.count / 2
        var floats = [Float](repeating: 0, count: sampleCount)

        pcmData.withUnsafeBytes { raw in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floats[i] = Float(int16Buffer[i]) / 32767.0
            }
        }

        return floats
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by the async download call
    }
}
