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

    @Test("does not repair short offline speech that is mostly covered")
    func skipsShortCoveredSpeechRegions() {
        let existing = [
            SpeechSegment(start: 20.0, end: 20.24, text: "short covered")
        ]
        let offline = [
            VadSegment(startTime: 20.0, endTime: 20.3)
        ]

        let repair = MeetingMicRepairPlanner.repairSegments(
            existingMicSegments: existing,
            offlineSpeechSegments: offline
        )

        #expect(repair.isEmpty)
    }

    @Test("does not repair short offline speech even when undercovered")
    func skipsShortUndercoveredSpeechRegions() {
        let existing = [
            SpeechSegment(start: 30.0, end: 30.12, text: "short partial")
        ]
        let offline = [
            VadSegment(startTime: 30.0, endTime: 30.3)
        ]

        let repair = MeetingMicRepairPlanner.repairSegments(
            existingMicSegments: existing,
            offlineSpeechSegments: offline
        )

        #expect(repair.isEmpty)
    }
}
