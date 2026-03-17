import Foundation
import os

/// Merges real-time mic recording with Nemotron chunk-by-chunk transcription.
/// Text appears at the cursor as the user speaks (~560ms per chunk).
///
/// Usage:
///   let controller = StreamingDictationController(transcriber: nemotron)
///   controller.onPartialText = { fullText in /* paste delta */ }
///   controller.start()
///   // ... user speaks ...
///   let finalText = controller.stop()
@available(macOS 15, *)
final class StreamingDictationController {
    /// Called with the full accumulated transcript so far (on a background thread).
    var onPartialText: ((String) -> Void)?

    private let transcriber: NemotronStreamingTranscriber
    private let recorder = StreamingMicRecorder()
    private var streamState: NemotronStreamingTranscriber.StreamState?
    private var sampleBuffer: [Float] = []
    private let bufferLock = OSAllocatedUnfairLock()
    private var fullTranscript = ""
    private var isActive = false
    private var processingChunk = false
    private let chunkSamples = 8960  // 560ms at 16kHz

    init(transcriber: NemotronStreamingTranscriber) {
        self.transcriber = transcriber
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        fullTranscript = ""
        sampleBuffer.removeAll()

        // Initialize streaming state
        Task {
            do {
                streamState = try await transcriber.makeStreamState()
            } catch {
                fputs("[streaming-dictation] failed to create stream state: \(error)\n", stderr)
                return
            }

            // Start mic recording — onAudioBuffer fires on AVAudioEngine's thread
            recorder.onAudioBuffer = { [weak self] samples in
                self?.handleAudioBuffer(samples)
            }

            do {
                try recorder.prepare()
                try recorder.start()
                fputs("[streaming-dictation] started\n", stderr)
            } catch {
                fputs("[streaming-dictation] mic start failed: \(error)\n", stderr)
            }
        }
    }

    /// Stop recording, process any remaining audio, return final transcript.
    func stop() -> String {
        guard isActive else { return fullTranscript }
        isActive = false

        // Stop mic
        let _ = recorder.stop()

        // Process remaining buffered samples
        let remaining: [Float] = bufferLock.withLock {
            let samples = sampleBuffer
            sampleBuffer.removeAll()
            return samples
        }

        if !remaining.isEmpty {
            // Pad to chunkSamples with zeros
            var padded = remaining
            if padded.count < chunkSamples {
                padded.append(contentsOf: [Float](repeating: 0, count: chunkSamples - padded.count))
            }
            // Process final chunk synchronously via semaphore
            let sem = DispatchSemaphore(value: 0)
            Task {
                await processChunk(padded)
                sem.signal()
            }
            sem.wait()
        }

        fputs("[streaming-dictation] stopped, transcript: \(fullTranscript.prefix(80))...\n", stderr)
        return fullTranscript
    }

    // MARK: - Audio Buffer Handling

    /// Called on AVAudioEngine's audio processing thread (4096 samples per call).
    private func handleAudioBuffer(_ samples: [Float]) {
        guard isActive else { return }

        var chunkToProcess: [Float]?

        bufferLock.withLock {
            sampleBuffer.append(contentsOf: samples)
            if sampleBuffer.count >= chunkSamples {
                chunkToProcess = Array(sampleBuffer.prefix(chunkSamples))
                sampleBuffer.removeFirst(chunkSamples)
            }
        }

        if let chunk = chunkToProcess, !processingChunk {
            processingChunk = true
            fputs("[streaming-dictation] chunk ready (\(chunk.count) samples), processing...\n", stderr)
            Task { [weak self] in
                await self?.processChunk(chunk)
                self?.processingChunk = false
            }
        }
    }

    /// Run one 560ms chunk through the Nemotron transcriber.
    private func processChunk(_ samples: [Float]) async {
        guard var state = streamState else {
            fputs("[streaming-dictation] no stream state, skipping chunk\n", stderr)
            return
        }

        do {
            let newText = try await transcriber.transcribeChunk(samples: samples, state: &state)
            streamState = state

            if !newText.isEmpty {
                fullTranscript += newText
                onPartialText?(fullTranscript)
            }
        } catch {
            fputs("[streaming-dictation] chunk error: \(error)\n", stderr)
        }
    }
}
