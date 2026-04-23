import DTLNAecCoreML
import Foundation

enum MeetingAecModelBundle {
    static let bundleName = "DTLNAecCoreML_DTLNAec512.bundle"

    static func resolve(
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> Bundle {
        let candidates = candidateURLs(mainBundle: mainBundle)

        for url in candidates {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        let searched = candidates.map(\.path).joined(separator: ", ")
        throw NSError(
            domain: "MeetingAecModelBundle",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate \(bundleName) in: \(searched)"]
        )
    }

    static func candidateURLs(mainBundle: Bundle = .main) -> [URL] {
        let rawCandidates = [
            mainBundle.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
            mainBundle.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
            mainBundle.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName, isDirectory: true),
        ].compactMap { $0 }

        var seen = Set<String>()
        return rawCandidates.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}

final class MeetingNeuralAec {
    private var processor: DTLNAecEchoProcessor?
    private var isLoaded = false

    private let frameSize = 512

    // Position-indexed streaming state — both streams track absolute sample position
    // so mic frame at position P is always paired with system frame at position P.
    // Accessed only from MeetingSession's chunkRotationQueue.
    private var systemSampleBuffer: [Float] = []
    private var systemSamplesReceived: Int = 0
    private var micSamplesReceived: Int = 0
    private var micFrameBuffer: [Float] = []

    /// Pre-load the DTLN-aec model so it's ready for processing.
    func preload() async {
        guard !isLoaded else { return }
        let proc = DTLNAecEchoProcessor(modelSize: .large)
        do {
            try await proc.loadModelsAsync(from: MeetingAecModelBundle.resolve())
            processor = proc
            isLoaded = true
            fputs("[meeting-aec] DTLN-aec model preloaded\n", stderr)
        } catch {
            fputs("[meeting-aec] DTLN-aec preload failed: \(error)\n", stderr)
        }
    }

    /// Reset processor state and streaming buffers for a new meeting.
    func resetForStreaming() {
        processor?.resetStates()
        systemSampleBuffer.removeAll(keepingCapacity: true)
        systemSamplesReceived = 0
        micSamplesReceived = 0
        micFrameBuffer.removeAll(keepingCapacity: true)
    }

    /// Buffer system audio samples indexed by absolute position.
    func feedSystemSamples(_ samples: [Float]) {
        systemSampleBuffer.append(contentsOf: samples)
        systemSamplesReceived += samples.count
    }

    /// Process mic samples through DTLN-aec, using position-aligned system reference.
    /// Mic position P is always paired with system position P — no drift.
    func processStreamingMic(_ micSamples: [Float]) -> [Float] {
        guard let processor else {
            fputs("[meeting-aec] processor not loaded, passing through raw mic audio\n", stderr)
            return micSamples
        }

        micFrameBuffer.append(contentsOf: micSamples)
        var cleaned: [Float] = []
        cleaned.reserveCapacity(micSamples.count)

        while micFrameBuffer.count >= frameSize {
            let micFrame = Array(micFrameBuffer.prefix(frameSize))
            micFrameBuffer.removeFirst(frameSize)

            // The system buffer stores samples starting from position 0.
            // micSamplesReceived tracks how many mic samples we've consumed so far.
            // We need system samples at the same absolute position.
            let systemPos = micSamplesReceived
            let systemFrame: [Float]
            if systemPos + frameSize <= systemSamplesReceived {
                // System samples available at this position
                systemFrame = Array(systemSampleBuffer[systemPos..<(systemPos + frameSize)])
            } else if systemPos < systemSamplesReceived {
                // Partial system samples available — pad remainder with silence
                let available = systemSamplesReceived - systemPos
                systemFrame = Array(systemSampleBuffer[systemPos..<systemSamplesReceived])
                    + [Float](repeating: 0, count: frameSize - available)
            } else {
                // System audio hasn't arrived yet for this position — use silence
                systemFrame = [Float](repeating: 0, count: frameSize)
            }

            autoreleasepool {
                processor.feedFarEnd(systemFrame)
                let cleanedFrame = processor.processNearEnd(micFrame)
                cleaned.append(contentsOf: cleanedFrame)
            }

            micSamplesReceived += frameSize
        }

        // Trim consumed system samples to prevent unbounded memory growth.
        // Keep only samples from micSamplesReceived onward (not yet consumed).
        let consumed = min(micSamplesReceived, systemSampleBuffer.count)
        if consumed > 16_000 { // trim every ~1s worth
            systemSampleBuffer.removeFirst(consumed)
            systemSamplesReceived -= consumed
            micSamplesReceived -= consumed
        }

        return cleaned
    }

    /// Flush remaining buffered mic samples (zero-padded to frame boundary).
    func flushStreamingMic() -> [Float] {
        guard let processor, !micFrameBuffer.isEmpty else { return [] }

        let actualCount = micFrameBuffer.count
        let padded = micFrameBuffer + [Float](repeating: 0, count: frameSize - actualCount)
        micFrameBuffer.removeAll(keepingCapacity: true)

        let systemPos = micSamplesReceived
        let systemFrame: [Float]
        if systemPos + frameSize <= systemSamplesReceived {
            systemFrame = Array(systemSampleBuffer[systemPos..<(systemPos + frameSize)])
        } else {
            systemFrame = [Float](repeating: 0, count: frameSize)
        }

        var result: [Float] = []
        autoreleasepool {
            processor.feedFarEnd(systemFrame)
            result = processor.processNearEnd(padded)
        }

        return Array(result.prefix(actualCount))
    }

    /// Whether the model is loaded and ready.
    var isReady: Bool { isLoaded && processor != nil }
}
