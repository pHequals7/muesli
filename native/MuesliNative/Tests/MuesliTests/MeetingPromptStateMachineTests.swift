import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingPromptStateMachine")
struct MeetingPromptStateMachineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ id: String = "googleMeet:meet.google.com/pwm-txwq-txy") -> MeetingCandidate {
        MeetingCandidate(
            id: id,
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/pwm-txwq-txy",
            evidence: [.micActive, .cameraActive, .browserURL, .foregroundApp],
            startedAt: now,
            meetingTitle: nil
        )
    }

    private func decision(
        _ machine: MeetingPromptStateMachine,
        candidate: MeetingCandidate?,
        visible: Bool = false,
        promptID: String? = nil,
        isRecording: Bool = false,
        isStartingRecording: Bool = false,
        isCalendarVisible: Bool = false,
        now: Date? = nil
    ) -> MeetingPromptDecision {
        machine.evaluate(
            candidate: candidate,
            detectionEnabled: true,
            isRecording: isRecording,
            isStartingRecording: isStartingRecording,
            isCalendarNotificationVisible: isCalendarVisible,
            visibility: MeetingPromptVisibility(isVisible: visible, currentPromptID: promptID, shownAt: nil),
            now: now ?? self.now
        )
    }

    @Test("eligible candidate shows within one evaluation")
    func eligibleCandidateShows() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate()

        let result = decision(machine, candidate: candidate)

        #expect(result.action == .show)
        #expect(result.candidate?.id == candidate.id)
    }

    @Test("visible state clears after auto-dismiss and does not immediately re-show same candidate")
    func autoDismissClearsVisibleState() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate()

        machine.markShown(candidate)
        machine.markAutoDismissed(candidate)
        let result = decision(machine, candidate: candidate)

        #expect(machine.visiblePromptID == nil)
        #expect(result.action == .none)
        #expect(result.reason == .autoDismissedCooldown)
    }

    @Test("new candidate can show after prior candidate auto-dismiss")
    func newCandidateAfterAutoDismissShows() {
        let machine = MeetingPromptStateMachine()
        let oldCandidate = candidate()
        let newCandidate = candidate("googleMeet:meet.google.com/abc-defg-hij")

        machine.markShown(oldCandidate)
        machine.markAutoDismissed(oldCandidate)
        let result = decision(machine, candidate: newCandidate)

        #expect(result.action == .show)
        #expect(result.candidate?.id == newCandidate.id)
    }

    @Test("user dismiss suppresses only that candidate")
    func userDismissSuppressesOnlyThatCandidate() {
        let machine = MeetingPromptStateMachine()
        let dismissed = candidate()
        let other = candidate("googleMeet:meet.google.com/abc-defg-hij")

        machine.markShown(dismissed)
        machine.markUserDismissed(dismissed, until: now.addingTimeInterval(120))

        #expect(decision(machine, candidate: dismissed).reason == .userDismissedSuppression)
        #expect(decision(machine, candidate: other).action == .show)
    }

    @Test("prompt does not show while recording or starting recording")
    func promptBlockedDuringRecordingStates() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate()

        #expect(decision(machine, candidate: candidate, isRecording: true).reason == .recording)
        #expect(decision(machine, candidate: candidate, isStartingRecording: true).reason == .recording)
    }

    @Test("calendar notification blocks detection notification without overwriting it")
    func calendarNotificationBlocksDetectionNotification() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate()

        let result = decision(machine, candidate: candidate, isCalendarVisible: true)

        #expect(result.action == .none)
        #expect(result.reason == .calendarNotificationVisible)
    }
}
