import Foundation

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
    private let workerClient: PythonWorkerClient
    private var loadedBackend: BackendOption?

    init(workerClient: PythonWorkerClient) {
        self.workerClient = workerClient
    }

    func preload(backend: BackendOption) async {
        do {
            _ = try await workerClient.preloadBackendAsync(option: backend)
            loadedBackend = backend
        } catch {
            fputs("[muesli-native] preload failed: \(error)\n", stderr)
        }
    }

    func transcribeDictation(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        let payload = try await workerClient.transcribeFileAsync(wavURL: url, option: backend, customWords: customWords)
        return mapResult(payload)
    }

    func transcribeMeeting(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        let payload = try await workerClient.transcribeFileAsync(wavURL: url, option: backend, customWords: customWords)
        return mapResult(payload)
    }

    func transcribeMeetingChunk(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        let payload = try await workerClient.transcribeMeetingChunkAsync(wavURL: url, option: backend, customWords: customWords)
        let isSilent = payload["is_silent"] as? Bool ?? false
        if isSilent {
            return SpeechTranscriptionResult(text: "", segments: [])
        }
        return mapResult(payload)
    }

    func shutdown() {
        workerClient.stop()
        loadedBackend = nil
    }

    private func mapResult(_ payload: [String: Any]) -> SpeechTranscriptionResult {
        let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        return SpeechTranscriptionResult(text: text, segments: segments)
    }
}
