import AVFoundation
import FluidAudio
import Foundation

enum MeetingMicRepairPlanner {
    private static let minimumCoverageRatio = 0.55
    private static let minimumRepairDuration: TimeInterval = 0.8

    static func repairSegments(
        existingMicSegments: [SpeechSegment],
        offlineSpeechSegments: [VadSegment]
    ) -> [VadSegment] {
        offlineSpeechSegments.filter { offlineSegment in
            guard offlineSegment.duration >= minimumRepairDuration else { return false }
            let coveredSeconds = overlapDuration(
                existingMicSegments: existingMicSegments,
                targetStart: offlineSegment.startTime,
                targetEnd: offlineSegment.endTime
            )
            let targetDuration = max(offlineSegment.duration, 0)
            guard targetDuration > 0 else { return false }
            return (coveredSeconds / targetDuration) < minimumCoverageRatio
        }
    }

    static func writeTemporaryWAV(samples: [Float]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-mic-repair", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        var pcmSamples = [Int16]()
        pcmSamples.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            pcmSamples.append(Int16(clamped * 32767.0))
        }

        var data = Data()
        let dataSize = UInt32(pcmSamples.count * MemoryLayout<Int16>.size)
        data.append(contentsOf: wavHeader(dataSize: dataSize))
        data.append(pcmSamples.withUnsafeBufferPointer { Data(buffer: $0) })
        try data.write(to: url, options: .atomic)
        return url
    }

    static func wavDurationSeconds(for url: URL) -> Double {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(audioFile.length) / sampleRate
    }

    private static func overlapDuration(
        existingMicSegments: [SpeechSegment],
        targetStart: TimeInterval,
        targetEnd: TimeInterval
    ) -> TimeInterval {
        existingMicSegments.reduce(0) { partialResult, segment in
            let overlapStart = max(segment.start, targetStart)
            let overlapEnd = min(segment.end, targetEnd)
            return partialResult + max(0, overlapEnd - overlapStart)
        }
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}
