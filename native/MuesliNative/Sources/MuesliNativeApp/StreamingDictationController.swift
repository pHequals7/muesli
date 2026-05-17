import Foundation
import CoreAudio
import os

/// Merges real-time mic recording with Nemotron chunk-by-chunk transcription.
/// Text appears at the cursor as the user speaks (~560ms per chunk).
///
/// Usage:
///   let controller = StreamingDictationController(transcriber: nemotron)
///   controller.onPartialText = { fullText in /* paste delta */ }
///   controller.start()
///   // ... user speaks ...
///   controller.stop { finalText in /* persist final text */ }
@available(macOS 15, *)
protocol NemotronStreamingTranscribing: AnyObject {
    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState
    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String
}

@available(macOS 15, *)
private final class NemotronStreamingTranscriberAdapter: NemotronStreamingTranscribing {
    private let transcriber: NemotronStreamingTranscriber

    init(_ transcriber: NemotronStreamingTranscriber) {
        self.transcriber = transcriber
    }

    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        try await transcriber.makeStreamState()
    }

    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        try await transcriber.transcribeChunk(samples: samples, state: &state)
    }
}

@available(macOS 15, *)
final class StreamingDictationController {
    /// Called with the full accumulated transcript so far (on a background thread).
    var onPartialText: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let transcriber: NemotronStreamingTranscribing
    private let recorder: StreamingDictationRecording
    private var streamState: NemotronStreamingTranscriber.StreamState?
    private var sampleBuffer: [Float] = []
    private let bufferLock = OSAllocatedUnfairLock()
    private var chunkQueue: [[Float]] = []
    private let queueLock = OSAllocatedUnfairLock()
    private var isDraining = false
    private let drainLock = OSAllocatedUnfairLock()
    private var fullTranscript = ""
    private var isActive = false
    private var activeSessionID: UUID?
    private var streamStateTask: Task<Void, Never>?
    private let chunkSamples = 8960  // 560ms at 16kHz
    private static let stopStreamStateTimeout: TimeInterval = 1.0
    private static let stopDrainTimeout: TimeInterval = 1.0

    init(
        transcriber: NemotronStreamingTranscriber,
        preferredInputDeviceID: AudioObjectID? = nil,
        recorder: StreamingDictationRecording = StreamingMicRecorder()
    ) {
        self.transcriber = NemotronStreamingTranscriberAdapter(transcriber)
        self.recorder = recorder
        recorder.preferredInputDeviceID = preferredInputDeviceID
    }

    init(
        transcriber: NemotronStreamingTranscribing,
        preferredInputDeviceID: AudioObjectID? = nil,
        recorder: StreamingDictationRecording = StreamingMicRecorder()
    ) {
        self.transcriber = transcriber
        self.recorder = recorder
        recorder.preferredInputDeviceID = preferredInputDeviceID
    }

    /// Pre-warm the ANE so first real chunk is fast. Call this early (e.g., on backend select).
    func warmup() {
        Task {
            do {
                var state = try await transcriber.makeStreamState()
                fputs("[streaming-dictation] warming up ANE...\n", stderr)
                let silence = [Float](repeating: 0, count: chunkSamples)
                _ = try? await transcriber.transcribeChunk(samples: silence, state: &state)
                fputs("[streaming-dictation] warmup done\n", stderr)
            } catch {
                fputs("[streaming-dictation] warmup failed: \(error)\n", stderr)
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }
        let sessionID = UUID()
        isActive = true
        activeSessionID = sessionID
        fullTranscript = ""
        sampleBuffer.removeAll()
        chunkQueue.removeAll()
        streamState = nil
        drainLock.withLock {
            isDraining = false
        }

        // Start mic IMMEDIATELY — don't block on state init or warmup
        recorder.onAudioBuffer = { [weak self] samples in
            self?.handleAudioBuffer(samples)
        }
        do {
            try recorder.prepare()
            try recorder.start()
            fputs("[streaming-dictation] mic started\n", stderr)
        } catch {
            fputs("[streaming-dictation] mic start failed: \(error)\n", stderr)
            resetActiveSession(cancelRecorder: true)
            return false
        }

        // Init stream state in background — audio buffers queue while this runs
        let initializationTask = Task {
            do {
                let state = try await transcriber.makeStreamState()
                guard self.isCurrentSession(sessionID) else { return }
                streamState = state
                fputs("[streaming-dictation] stream state ready, draining queued chunks\n", stderr)
                startDrainIfNeeded(sessionID: sessionID)
            } catch {
                guard self.isCurrentSession(sessionID) else { return }
                fputs("[streaming-dictation] failed to create stream state: \(error)\n", stderr)
                self.failActiveSession(sessionID: sessionID, error: error)
            }
        }
        streamStateTask = initializationTask
        return true
    }

    /// Stop recording and finish queued audio off the caller's thread.
    func stop(completion: @escaping (String) -> Void) {
        guard let sessionID = activeSessionID else {
            completion(fullTranscript)
            return
        }
        isActive = false

        let _ = recorder.stop()

        // Collect remaining buffered samples
        let remaining: [Float] = bufferLock.withLock {
            let samples = sampleBuffer
            sampleBuffer.removeAll()
            return samples
        }

        if !remaining.isEmpty {
            var padded = remaining
            if padded.count < chunkSamples {
                padded.append(contentsOf: [Float](repeating: 0, count: chunkSamples - padded.count))
            }
            let finalChunk = padded
            queueLock.withLock {
                chunkQueue.append(finalChunk)
            }
        }

        startDrainIfNeeded(sessionID: sessionID)
        let initializationTask = streamStateTask
        Task {
            await self.waitForStreamStateInitialization(
                initializationTask,
                sessionID: sessionID,
                timeout: Self.stopStreamStateTimeout
            )
            guard self.isCurrentSession(sessionID) else {
                completion(self.fullTranscript)
                return
            }
            self.startDrainIfNeeded(sessionID: sessionID)
            await self.waitForDrain(sessionID: sessionID, timeout: Self.stopDrainTimeout)
            let transcript = self.finishStoppedSession(sessionID: sessionID)
            completion(transcript)
        }
    }

    func cancel() {
        resetActiveSession(cancelRecorder: true)
    }

    private func failActiveSession(sessionID: UUID, error: Error) {
        guard isCurrentSession(sessionID) else { return }
        resetActiveSession(cancelRecorder: true)
        onFailure?(error)
    }

    private func resetActiveSession(cancelRecorder: Bool) {
        isActive = false
        activeSessionID = nil
        streamStateTask?.cancel()
        streamStateTask = nil
        if cancelRecorder {
            recorder.cancel()
        }
        bufferLock.withLock {
            sampleBuffer.removeAll()
        }
        queueLock.withLock {
            chunkQueue.removeAll()
        }
        drainLock.withLock {
            isDraining = false
        }
        streamState = nil
    }

    // MARK: - Audio Buffer Handling

    /// Called on AVAudioEngine's audio processing thread (4096 samples per call).
    private func handleAudioBuffer(_ samples: [Float]) {
        guard isActive else { return }

        let newChunks = bufferLock.withLock { () -> [[Float]] in
            var chunks: [[Float]] = []
            sampleBuffer.append(contentsOf: samples)
            while sampleBuffer.count >= chunkSamples {
                chunks.append(Array(sampleBuffer.prefix(chunkSamples)))
                sampleBuffer.removeFirst(chunkSamples)
            }
            return chunks
        }

        if !newChunks.isEmpty {
            queueLock.withLock {
                chunkQueue.append(contentsOf: newChunks)
            }
            // Kick off serial processing if not already running
            guard let sessionID = activeSessionID else { return }
            startDrainIfNeeded(sessionID: sessionID)
        }
    }

    private func startDrainIfNeeded(sessionID: UUID) {
        guard isCurrentSession(sessionID) else { return }
        guard streamState != nil else { return }
        let shouldStart = drainLock.withLock {
            if isDraining { return false }
            isDraining = true
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in
            await self?.drainQueue(sessionID: sessionID)
            self?.markDrainFinished(sessionID: sessionID)
        }
    }

    private func markDrainFinished(sessionID: UUID) {
        let shouldContinue = streamState != nil && queueLock.withLock { !chunkQueue.isEmpty }
        drainLock.withLock {
            isDraining = false
        }
        if shouldContinue {
            startDrainIfNeeded(sessionID: sessionID)
        }
    }

    private func isCurrentSession(_ sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }

    private func waitForDrain(sessionID: UUID, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isCurrentSession(sessionID) else { return }
            let queueIsEmpty = queueLock.withLock { chunkQueue.isEmpty }
            let currentlyDraining = drainLock.withLock { isDraining }
            if queueIsEmpty && !currentlyDraining { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fputs("[streaming-dictation] stop drain timed out\n", stderr)
    }

    private func waitForStreamStateInitialization(
        _ task: Task<Void, Never>?,
        sessionID: UUID,
        timeout: TimeInterval
    ) async {
        guard let task else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel()
            }
            await group.next()
            group.cancelAll()
        }
        if isCurrentSession(sessionID), streamState == nil {
            fputs("[streaming-dictation] stream state init timed out during stop\n", stderr)
        }
    }

    private func finishStoppedSession(sessionID: UUID) -> String {
        guard isCurrentSession(sessionID) else { return fullTranscript }
        activeSessionID = nil
        streamStateTask = nil
        queueLock.withLock {
            chunkQueue.removeAll()
        }
        drainLock.withLock {
            isDraining = false
        }
        streamState = nil
        let transcript = fullTranscript
        fputs("[streaming-dictation] stopped, transcript (\(transcript.count) chars): \(transcript.prefix(100))...\n", stderr)
        return transcript
    }

    /// Process all queued chunks serially, one at a time.
    private func drainQueue(sessionID: UUID) async {
        while true {
            guard isCurrentSession(sessionID) else { return }
            let chunk: [Float]? = queueLock.withLock {
                chunkQueue.isEmpty ? nil : chunkQueue.removeFirst()
            }
            guard let chunk else { return }

            guard var state = streamState else {
                guard isCurrentSession(sessionID) else { return }
                queueLock.withLock {
                    chunkQueue.insert(chunk, at: 0)
                }
                return
            }

            let start = CFAbsoluteTimeGetCurrent()
            do {
                let newText = try await transcriber.transcribeChunk(samples: chunk, state: &state)
                guard isCurrentSession(sessionID) else { return }
                streamState = state
                let elapsed = CFAbsoluteTimeGetCurrent() - start

                if !newText.isEmpty {
                    fullTranscript += newText
                    fputs("[streaming-dictation] chunk → \"\(newText)\" (\(String(format: "%.0f", elapsed * 1000))ms)\n", stderr)
                    onPartialText?(fullTranscript)
                } else {
                    fputs("[streaming-dictation] chunk → (silence) (\(String(format: "%.0f", elapsed * 1000))ms)\n", stderr)
                }
            } catch {
                fputs("[streaming-dictation] chunk error: \(error)\n", stderr)
            }
        }
    }
}
