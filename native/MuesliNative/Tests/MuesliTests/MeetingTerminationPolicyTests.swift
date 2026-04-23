import Testing
@testable import MuesliNativeApp

@Suite("Meeting termination policy")
struct MeetingTerminationPolicyTests {
    @Test("allows termination when no meeting lifecycle is active")
    func allowsIdleTermination() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: false,
                isRecording: false,
                isStopping: false
            ) == .none
        )
    }

    @Test("warns while a meeting is starting")
    func warnsDuringStart() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: true,
                hasActiveSession: false,
                isRecording: false,
                isStopping: false
            ) == .starting
        )
    }

    @Test("warns while a meeting is recording")
    func warnsDuringRecording() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: true,
                isStopping: false
            ) == .recording
        )
    }

    @Test("warns while a stopped meeting is still processing")
    func warnsDuringProcessing() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: false,
                isStopping: true
            ) == .processing
        )
    }
}
