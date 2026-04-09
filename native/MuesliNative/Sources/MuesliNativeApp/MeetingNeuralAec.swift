import DTLNAecCoreML
import DTLNAec512
import Foundation

final class MeetingNeuralAec {
    private var processor: DTLNAecEchoProcessor?
    private var isLoaded = false

    // Streaming state — accessed only from MeetingSession's chunkRotationQueue
    private let frameSize = 512
    private var systemRingBuffer: [Float] = []
    private var micFrameBuffer: [Float] = []
    /// Cap system ring buffer at ~2s of audio to prevent unbounded growth
    private let maxSystemBufferSize = 16_000 * 2

    /// Pre-load the DTLN-aec model so it's ready for real-time processing.
    func preload() async {
        guard !isLoaded else { return }
        let proc = DTLNAecEchoProcessor(modelSize: .large)
        do {
            try await proc.loadModelsAsync(from: DTLNAec512.bundle)
            processor = proc
            isLoaded = true
            fputs("[meeting-aec] DTLN-aec model preloaded\n", stderr)
        } catch {
            fputs("[meeting-aec] DTLN-aec preload failed: \(error)\n", stderr)
        }
    }

    /// Reset processor state and streaming buffers for a new meeting.
    /// Call from chunkRotationQueue before starting real-time processing.
    func resetForStreaming() {
        processor?.resetStates()
        systemRingBuffer.removeAll(keepingCapacity: true)
        micFrameBuffer.removeAll(keepingCapacity: true)
    }

    /// Buffer system audio samples as far-end reference for AEC.
    /// Call from chunkRotationQueue when system audio samples arrive.
    func feedSystemSamples(_ samples: [Float]) {
        systemRingBuffer.append(contentsOf: samples)
        // Trim if buffer grows too large (system audio arriving faster than mic consumes it)
        if systemRingBuffer.count > maxSystemBufferSize {
            systemRingBuffer.removeFirst(systemRingBuffer.count - maxSystemBufferSize)
        }
    }

    /// Process mic samples through DTLN-aec in real-time, returning cleaned audio.
    /// Accumulates samples into 512-frame chunks and processes each through the model.
    /// Call from chunkRotationQueue when mic audio samples arrive.
    func processStreamingMic(_ micSamples: [Float]) -> [Float] {
        guard let processor else { return micSamples }

        micFrameBuffer.append(contentsOf: micSamples)
        var cleaned: [Float] = []
        cleaned.reserveCapacity(micSamples.count)

        while micFrameBuffer.count >= frameSize {
            let micFrame = Array(micFrameBuffer.prefix(frameSize))
            micFrameBuffer.removeFirst(frameSize)

            let systemFrame: [Float]
            if systemRingBuffer.count >= frameSize {
                systemFrame = Array(systemRingBuffer.prefix(frameSize))
                systemRingBuffer.removeFirst(frameSize)
            } else {
                // No system audio available — feed silence as reference
                systemFrame = [Float](repeating: 0, count: frameSize)
            }

            // autoreleasepool prevents CoreML GPU/ANE buffer accumulation
            // that causes MLE5BindEmptyMemoryObjectToPort crash in long meetings
            autoreleasepool {
                processor.feedFarEnd(systemFrame)
                let cleanedFrame = processor.processNearEnd(micFrame)
                cleaned.append(contentsOf: cleanedFrame)
            }
        }

        return cleaned
    }

    /// Whether the model is loaded and ready for streaming.
    var isReady: Bool { isLoaded && processor != nil }
}
