import FluidAudio
import Foundation

struct MeetingLocalSpeechGuardDecision {
    let preferredMicSegments: [SpeechSegment]
    let revertedToOriginal: Bool
    let reason: String
    let originalCoverageRatio: Double
    let reconciledCoverageRatio: Double
}

enum MeetingLocalSpeechGuard {
    private static let minimumCoverageLossToRevert = 0.12
    private static let minimumUncoveredSpeechIncreaseToRevert: TimeInterval = 1.0

    static func decide(
        originalMicSegments: [SpeechSegment],
        reconciledMicSegments: [SpeechSegment],
        offlineSpeechSegments: [VadSegment],
        chunkHealth: MeetingTranscriptChunkHealthSnapshot
    ) -> MeetingLocalSpeechGuardDecision {
        let originalHealth = MeetingTranscriptHealthMonitor.evaluate(
            existingSegments: originalMicSegments,
            offlineSpeechSegments: offlineSpeechSegments,
            chunkHealth: chunkHealth
        )
        let reconciledHealth = MeetingTranscriptHealthMonitor.evaluate(
            existingSegments: reconciledMicSegments,
            offlineSpeechSegments: offlineSpeechSegments,
            chunkHealth: chunkHealth
        )

        let coverageLoss = originalHealth.speechCoverageRatio - reconciledHealth.speechCoverageRatio
        let uncoveredSpeechIncrease = reconciledHealth.uncoveredSpeechDuration - originalHealth.uncoveredSpeechDuration
        let shouldRevert =
            coverageLoss >= minimumCoverageLossToRevert &&
            uncoveredSpeechIncrease >= minimumUncoveredSpeechIncreaseToRevert

        return MeetingLocalSpeechGuardDecision(
            preferredMicSegments: shouldRevert ? originalMicSegments : reconciledMicSegments,
            revertedToOriginal: shouldRevert,
            reason: shouldRevert
                ? "reconciler removed too much local speech"
                : "reconciled mic coverage acceptable",
            originalCoverageRatio: originalHealth.speechCoverageRatio,
            reconciledCoverageRatio: reconciledHealth.speechCoverageRatio
        )
    }
}
