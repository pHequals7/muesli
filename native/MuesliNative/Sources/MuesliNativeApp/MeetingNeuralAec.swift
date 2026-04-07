import DTLNAecCoreML
import DTLNAec512
import Foundation

enum MeetingNeuralAec {
    /// Process full-session mic recording through DTLN-aec to remove system audio bleed.
    /// Processes in batches with autorelease pools to prevent CoreML GPU memory exhaustion.
    static func cleanMicAudio(
        micSamples: [Float],
        systemSamples: [Float]
    ) async -> [Float]? {
        guard !micSamples.isEmpty, !systemSamples.isEmpty else { return nil }

        let processor = DTLNAecEchoProcessor(modelSize: .large)
        do {
            try await processor.loadModelsAsync(from: DTLNAec512.bundle)
        } catch {
            fputs("[meeting-aec] failed to load DTLN-aec models: \(error)\n", stderr)
            return nil
        }

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
        processor.resetStates()

        fputs("[meeting-aec] DTLN-aec processed \(micLength) mic samples (system=\(systemLength)) → \(cleanedSamples.count) cleaned samples\n", stderr)
        return cleanedSamples
    }

    /// Write cleaned Float32 samples to a temporary 16kHz mono WAV file.
    static func writeTemporaryWAV(samples: [Float]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-aec-cleaned", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767)
        }

        var data = Data()
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(int16Samples.count * 2)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        int16Samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

        try data.write(to: url)
        return url
    }
}
