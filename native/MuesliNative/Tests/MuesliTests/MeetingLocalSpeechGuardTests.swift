import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("MeetingLocalSpeechGuard")
struct MeetingLocalSpeechGuardTests {

    @Test("reverts to original mic turns when reconciliation erases local speech coverage")
    func revertsWhenCoverageDropsSharply() {
        let original = [
            SpeechSegment(start: 0.0, end: 2.9, text: "covered"),
            SpeechSegment(start: 4.0, end: 5.9, text: "covered again"),
        ]
        let reconciled: [SpeechSegment] = []
        let offline = [
            VadSegment(startTime: 0.0, endTime: 3.0),
            VadSegment(startTime: 4.0, endTime: 6.0),
        ]

        let decision = MeetingLocalSpeechGuard.decide(
            originalMicSegments: original,
            reconciledMicSegments: reconciled,
            offlineSpeechSegments: offline,
            chunkHealth: MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: 2,
                emptyChunkCount: 0,
                failedChunkCount: 0
            )
        )

        #expect(decision.revertedToOriginal)
        #expect(decision.preferredMicSegments.count == 2)
        #expect(decision.originalCoverageRatio > decision.reconciledCoverageRatio)
    }

    @Test("keeps reconciled mic turns when coverage remains close")
    func keepsReconciledWhenCoverageIsSimilar() {
        let original = [
            SpeechSegment(start: 0.0, end: 2.8, text: "covered"),
            SpeechSegment(start: 4.0, end: 5.8, text: "covered again"),
        ]
        let reconciled = [
            SpeechSegment(start: 0.0, end: 2.8, text: "covered"),
            SpeechSegment(start: 4.0, end: 5.0, text: "covered"),
        ]
        let offline = [
            VadSegment(startTime: 0.0, endTime: 3.0),
            VadSegment(startTime: 4.0, endTime: 6.0),
        ]

        let decision = MeetingLocalSpeechGuard.decide(
            originalMicSegments: original,
            reconciledMicSegments: reconciled,
            offlineSpeechSegments: offline,
            chunkHealth: MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: 2,
                emptyChunkCount: 0,
                failedChunkCount: 0
            )
        )

        #expect(!decision.revertedToOriginal)
        #expect(decision.preferredMicSegments.count == 2)
        #expect(decision.preferredMicSegments[1].text == "covered")
    }
}
