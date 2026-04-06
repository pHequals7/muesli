import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("MeetingTranscriptHealthMonitor")
struct MeetingTranscriptHealthMonitorTests {

    @Test("accepts healthy mic coverage without repair")
    func acceptsHealthyCoverage() {
        let mic = [
            SpeechSegment(start: 0.0, end: 2.8, text: "hello there"),
            SpeechSegment(start: 4.0, end: 6.7, text: "another point")
        ]
        let offline = [
            VadSegment(startTime: 0.0, endTime: 3.0),
            VadSegment(startTime: 4.0, endTime: 7.0)
        ]

        let snapshot = MeetingTranscriptHealthMonitor.evaluate(
            existingSegments: mic,
            offlineSpeechSegments: offline,
            chunkHealth: MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: 2,
                emptyChunkCount: 0,
                failedChunkCount: 0
            )
        )

        #expect(snapshot.action == .accept)
        #expect(snapshot.speechCoverageRatio > 0.9)
    }

    @Test("returns selective repair for isolated uncovered speech")
    func selectiveRepairForIsolatedGap() {
        let mic = [
            SpeechSegment(start: 0.0, end: 2.9, text: "covered"),
            SpeechSegment(start: 8.0, end: 10.8, text: "covered later")
        ]
        let offline = [
            VadSegment(startTime: 0.0, endTime: 3.0),
            VadSegment(startTime: 4.0, endTime: 6.0),
            VadSegment(startTime: 8.0, endTime: 11.0)
        ]

        let snapshot = MeetingTranscriptHealthMonitor.evaluate(
            existingSegments: mic,
            offlineSpeechSegments: offline,
            chunkHealth: MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: 2,
                emptyChunkCount: 0,
                failedChunkCount: 0
            )
        )

        switch snapshot.action {
        case .selectiveRepair(let segments):
            #expect(segments.count == 1)
            #expect(segments[0].startTime == 4.0)
            #expect(segments[0].endTime == 6.0)
        default:
            Issue.record("Expected selective repair action")
        }
    }

    @Test("falls back when mic coverage is broadly poor")
    func fallsBackWhenCoverageIsPoor() {
        let mic: [SpeechSegment] = []
        let offline = [
            VadSegment(startTime: 0.0, endTime: 4.0),
            VadSegment(startTime: 5.0, endTime: 8.0)
        ]

        let snapshot = MeetingTranscriptHealthMonitor.evaluate(
            existingSegments: mic,
            offlineSpeechSegments: offline,
            chunkHealth: MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: 0,
                emptyChunkCount: 0,
                failedChunkCount: 3
            )
        )

        #expect(snapshot.action == .fullFallback(reason: "no_live_segments"))
    }
}
