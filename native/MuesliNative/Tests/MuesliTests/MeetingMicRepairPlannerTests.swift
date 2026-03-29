import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("MeetingMicRepairPlanner")
struct MeetingMicRepairPlannerTests {

    @Test("repairs offline speech regions with no mic coverage")
    func repairsUncoveredSpeechRegions() {
        let existing = [
            SpeechSegment(start: 0.0, end: 3.0, text: "covered")
        ]
        let offline = [
            VadSegment(startTime: 0.0, endTime: 3.0),
            VadSegment(startTime: 5.0, endTime: 8.0)
        ]

        let repair = MeetingMicRepairPlanner.repairSegments(
            existingMicSegments: existing,
            offlineSpeechSegments: offline
        )

        #expect(repair.count == 1)
        #expect(repair[0].startTime == 5.0)
        #expect(repair[0].endTime == 8.0)
    }

    @Test("does not repair sufficiently covered offline speech")
    func skipsCoveredSpeechRegions() {
        let existing = [
            SpeechSegment(start: 10.0, end: 12.6, text: "mostly covered")
        ]
        let offline = [
            VadSegment(startTime: 10.0, endTime: 13.0)
        ]

        let repair = MeetingMicRepairPlanner.repairSegments(
            existingMicSegments: existing,
            offlineSpeechSegments: offline
        )

        #expect(repair.isEmpty)
    }

    @Test("builds fallback speech segment when timings are not meaningful")
    func buildsFallbackSpeechSegment() {
        let result = SpeechTranscriptionResult(
            text: "hello world",
            segments: [SpeechSegment(start: 0, end: 0, text: "hello world")]
        )

        let segments = MeetingMicRepairPlanner.makeSpeechSegments(
            from: result,
            startTime: 4.0,
            endTime: 7.0
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 4.0)
        #expect(segments[0].end == 7.0)
        #expect(segments[0].text == "hello world")
    }
}
