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
}
