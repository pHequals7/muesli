import FluidAudio
import Foundation
import os

struct MeetingTranscriptChunkHealthSnapshot: Sendable {
    let successfulChunkCount: Int
    let emptyChunkCount: Int
    let failedChunkCount: Int

    var attemptedChunkCount: Int {
        successfulChunkCount + emptyChunkCount + failedChunkCount
    }

    var failedChunkRate: Double {
        guard attemptedChunkCount > 0 else { return 0 }
        return Double(failedChunkCount) / Double(attemptedChunkCount)
    }
}

final class MeetingTranscriptChunkHealthTracker {
    private struct State {
        var successfulChunkCount = 0
        var emptyChunkCount = 0
        var failedChunkCount = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func noteSuccessfulChunk() {
        lock.withLock { $0.successfulChunkCount += 1 }
    }

    func noteEmptyChunk() {
        lock.withLock { $0.emptyChunkCount += 1 }
    }

    func noteFailedChunk() {
        lock.withLock { $0.failedChunkCount += 1 }
    }

    func snapshot() -> MeetingTranscriptChunkHealthSnapshot {
        lock.withLock { state in
            MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: state.successfulChunkCount,
                emptyChunkCount: state.emptyChunkCount,
                failedChunkCount: state.failedChunkCount
            )
        }
    }
}

enum MeetingTranscriptRecoveryAction: Equatable {
    case accept
    case selectiveRepair([VadSegment])
    case fullFallback(reason: String)

    static func == (lhs: MeetingTranscriptRecoveryAction, rhs: MeetingTranscriptRecoveryAction) -> Bool {
        switch (lhs, rhs) {
        case (.accept, .accept):
            return true
        case let (.fullFallback(lhsReason), .fullFallback(rhsReason)):
            return lhsReason == rhsReason
        case let (.selectiveRepair(lhsSegments), .selectiveRepair(rhsSegments)):
            guard lhsSegments.count == rhsSegments.count else { return false }
            return zip(lhsSegments, rhsSegments).allSatisfy { lhsSegment, rhsSegment in
                lhsSegment.startTime == rhsSegment.startTime && lhsSegment.endTime == rhsSegment.endTime
            }
        default:
            return false
        }
    }
}

struct MeetingTranscriptHealthSnapshot: Sendable {
    let evaluatedSpeechSegmentCount: Int
    let totalEvaluatedSpeechDuration: TimeInterval
    let coveredSpeechDuration: TimeInterval
    let uncoveredSpeechDuration: TimeInterval
    let speechCoverageRatio: Double
    let chunkHealth: MeetingTranscriptChunkHealthSnapshot
    let action: MeetingTranscriptRecoveryAction

    var summaryLine: String {
        "[meeting] transcript health coverage=\(String(format: "%.2f", speechCoverageRatio)) " +
        "covered=\(String(format: "%.1fs", coveredSpeechDuration)) " +
        "uncovered=\(String(format: "%.1fs", uncoveredSpeechDuration)) " +
        "speechSegments=\(evaluatedSpeechSegmentCount) " +
        "chunks(success=\(chunkHealth.successfulChunkCount), empty=\(chunkHealth.emptyChunkCount), failed=\(chunkHealth.failedChunkCount)) " +
        "action=\(actionDescription)"
    }

    private var actionDescription: String {
        switch action {
        case .accept:
            return "accept"
        case .selectiveRepair(let segments):
            return "repair(\(segments.count))"
        case .fullFallback(let reason):
            return "full_fallback(\(reason))"
        }
    }
}

enum MeetingTranscriptHealthMonitor {
    private static let minimumEvaluatedSpeechDuration: TimeInterval = 0.8
    private static let minimumCoverageRatio = 0.55
    private static let fullFallbackCoverageThreshold = 0.60
    private static let degradedCoverageThreshold = 0.80
    private static let minimumFallbackSpeechDuration: TimeInterval = 1.5
    private static let widespreadUncoveredSpeechThreshold: TimeInterval = 8.0
    private static let widespreadUncoveredSpeechFraction = 0.30
    private static let systemicFailureRateThreshold = 0.35
    private static let minimumChunksForSystemicFailure = 4

    static func evaluate(
        existingSegments: [SpeechSegment],
        offlineSpeechSegments: [VadSegment],
        chunkHealth: MeetingTranscriptChunkHealthSnapshot
    ) -> MeetingTranscriptHealthSnapshot {
        let evaluatedSpeechSegments = offlineSpeechSegments.filter { $0.duration >= minimumEvaluatedSpeechDuration }
        let coverage = coverageSummary(
            existingSegments: existingSegments,
            offlineSpeechSegments: evaluatedSpeechSegments
        )

        let action: MeetingTranscriptRecoveryAction
        if coverage.totalEvaluatedSpeechDuration < minimumFallbackSpeechDuration {
            action = .accept
        } else if existingSegments.isEmpty {
            action = .fullFallback(reason: "no_live_segments")
        } else if coverage.speechCoverageRatio < fullFallbackCoverageThreshold {
            action = .fullFallback(reason: "low_speech_coverage")
        } else if coverage.uncoveredSpeechDuration >= max(
            widespreadUncoveredSpeechThreshold,
            coverage.totalEvaluatedSpeechDuration * widespreadUncoveredSpeechFraction
        ) {
            action = .fullFallback(reason: "widespread_uncovered_speech")
        } else if chunkHealth.attemptedChunkCount >= minimumChunksForSystemicFailure,
                  chunkHealth.failedChunkRate >= systemicFailureRateThreshold,
                  coverage.speechCoverageRatio < degradedCoverageThreshold {
            action = .fullFallback(reason: "systemic_chunk_failures")
        } else if !coverage.repairCandidates.isEmpty {
            action = .selectiveRepair(coverage.repairCandidates)
        } else {
            action = .accept
        }

        return MeetingTranscriptHealthSnapshot(
            evaluatedSpeechSegmentCount: evaluatedSpeechSegments.count,
            totalEvaluatedSpeechDuration: coverage.totalEvaluatedSpeechDuration,
            coveredSpeechDuration: coverage.coveredSpeechDuration,
            uncoveredSpeechDuration: coverage.uncoveredSpeechDuration,
            speechCoverageRatio: coverage.speechCoverageRatio,
            chunkHealth: chunkHealth,
            action: action
        )
    }

    private struct CoverageSummary {
        let totalEvaluatedSpeechDuration: TimeInterval
        let coveredSpeechDuration: TimeInterval
        let uncoveredSpeechDuration: TimeInterval
        let speechCoverageRatio: Double
        let repairCandidates: [VadSegment]
    }

    private static func coverageSummary(
        existingSegments: [SpeechSegment],
        offlineSpeechSegments: [VadSegment]
    ) -> CoverageSummary {
        var totalEvaluatedSpeechDuration: TimeInterval = 0
        var coveredSpeechDuration: TimeInterval = 0
        var uncoveredSpeechDuration: TimeInterval = 0
        var repairCandidates: [VadSegment] = []

        for offlineSegment in offlineSpeechSegments {
            let duration = max(offlineSegment.duration, 0)
            guard duration > 0 else { continue }

            totalEvaluatedSpeechDuration += duration
            let covered = min(duration, overlapDuration(
                existingSegments: existingSegments,
                targetStart: offlineSegment.startTime,
                targetEnd: offlineSegment.endTime
            ))
            coveredSpeechDuration += covered
            uncoveredSpeechDuration += max(0, duration - covered)

            if (covered / duration) < minimumCoverageRatio {
                repairCandidates.append(offlineSegment)
            }
        }

        let speechCoverageRatio = totalEvaluatedSpeechDuration > 0
            ? coveredSpeechDuration / totalEvaluatedSpeechDuration
            : 1.0

        return CoverageSummary(
            totalEvaluatedSpeechDuration: totalEvaluatedSpeechDuration,
            coveredSpeechDuration: coveredSpeechDuration,
            uncoveredSpeechDuration: uncoveredSpeechDuration,
            speechCoverageRatio: speechCoverageRatio,
            repairCandidates: repairCandidates
        )
    }

    private static func overlapDuration(
        existingSegments: [SpeechSegment],
        targetStart: TimeInterval,
        targetEnd: TimeInterval
    ) -> TimeInterval {
        existingSegments.reduce(0) { partialResult, segment in
            let overlapStart = max(segment.start, targetStart)
            let overlapEnd = min(segment.end, targetEnd)
            return partialResult + max(0, overlapEnd - overlapStart)
        }
    }
}
