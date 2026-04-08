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
        try WavWriter.writeTemporaryWAV(samples: samples, directoryName: "muesli-meeting-mic-repair")
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

}
