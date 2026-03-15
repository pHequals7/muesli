import Foundation

extension PythonWorkerClient {
    func preloadBackendAsync(option: BackendOption) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            preloadBackend(option: option) { result in
                continuation.resume(with: result)
            }
        }
    }

    func transcribeFileAsync(wavURL: URL, option: BackendOption, customWords: [[String: Any]] = []) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            transcribeFile(wavURL: wavURL, option: option, customWords: customWords) { result in
                continuation.resume(with: result)
            }
        }
    }

    func transcribeMeetingChunkAsync(wavURL: URL, option: BackendOption, customWords: [[String: Any]] = []) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            transcribeMeetingChunk(wavURL: wavURL, option: option, customWords: customWords) { result in
                continuation.resume(with: result)
            }
        }
    }

    func downloadModelAsync(option: BackendOption, progress: @escaping PythonWorkerClient.ProgressHandler) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            downloadModel(option: option, progress: progress) { result in
                continuation.resume(with: result)
            }
        }
    }
}
