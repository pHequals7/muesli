import DTLNAecCoreML
import DTLNAec512
import Foundation

final class MeetingNeuralAec {
    private var processor: DTLNAecEchoProcessor?
    private var isLoaded = false

    /// Pre-load the DTLN-aec model so it's ready when the meeting stops.
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

    /// Process full-session mic recording through DTLN-aec to remove system audio bleed.
    /// Processes in batches with autorelease pools to prevent CoreML GPU memory exhaustion.
    func cleanMicAudio(
        micSamples: [Float],
        systemSamples: [Float]
    ) async -> [Float]? {
        guard !micSamples.isEmpty, !systemSamples.isEmpty else { return nil }

        if !isLoaded {
            await preload()
        }
        guard let processor else { return nil }

        // Reset state from any previous meeting
        processor.resetStates()

        let micLength = micSamples.count
        let systemLength = systemSamples.count
        let frameSize = 512 // ~32ms at 16kHz
        let batchSize = 500 // process 500 frames (~16s) per autorelease batch
        var cleanedSamples: [Float] = []
        cleanedSamples.reserveCapacity(micLength)

        var frameIndex = 0
        for offset in stride(from: 0, to: micLength, by: frameSize) {
            let end = min(offset + frameSize, micLength)
            let micFrame = Array(micSamples[offset..<end])
            // Feed system audio as reference; use silence if system recording is shorter
            let systemFrame: [Float]
            if offset < systemLength {
                let sysEnd = min(offset + frameSize, systemLength)
                systemFrame = Array(systemSamples[offset..<sysEnd])
            } else {
                systemFrame = [Float](repeating: 0, count: end - offset)
            }

            autoreleasepool {
                processor.feedFarEnd(systemFrame)
                let cleaned = processor.processNearEnd(micFrame)
                cleanedSamples.append(contentsOf: cleaned)
            }

            frameIndex += 1

            // Yield periodically to let CoreML release GPU buffers
            if frameIndex % batchSize == 0 {
                await Task.yield()
            }
        }

        let remaining = processor.flush()
        cleanedSamples.append(contentsOf: remaining)

        fputs("[meeting-aec] DTLN-aec processed \(micLength) mic samples (system=\(systemLength)) → \(cleanedSamples.count) cleaned samples\n", stderr)
        return cleanedSamples
    }
}
