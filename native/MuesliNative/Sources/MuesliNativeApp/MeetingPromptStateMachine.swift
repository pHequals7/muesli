import Foundation

struct MeetingPromptVisibility {
    let isVisible: Bool
    let currentPromptID: String?
    let shownAt: Date?
}

struct MeetingPromptDecision: Equatable {
    enum Action: Equatable {
        case show
        case hide
        case none
    }

    enum Reason: Equatable {
        case eligible
        case noCandidate
        case disabled
        case calendarNotificationVisible
        case recording
        case promptAlreadyVisible
        case autoDismissedCooldown
        case userDismissedSuppression
    }

    let action: Action
    let candidate: MeetingCandidate?
    let reason: Reason
}

final class MeetingPromptStateMachine {
    private(set) var visiblePromptID: String?
    private var userSuppressedUntilByID: [String: Date] = [:]
    private var autoDismissedUntilByID: [String: Date] = [:]
    private var lastCandidateID: String?
    private let autoDismissCooldown: TimeInterval

    init(autoDismissCooldown: TimeInterval = 120) {
        self.autoDismissCooldown = autoDismissCooldown
    }

    func evaluate(
        candidate: MeetingCandidate?,
        detectionEnabled: Bool,
        isRecording: Bool,
        isStartingRecording: Bool,
        isCalendarNotificationVisible: Bool,
        visibility: MeetingPromptVisibility,
        now: Date
    ) -> MeetingPromptDecision {
        expireUserSuppressions(now: now)
        expireAutoDismissSuppressions(now: now)
        reconcileVisibility(visibility)

        guard detectionEnabled else {
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: nil, reason: .disabled)
                : MeetingPromptDecision(action: .hide, candidate: nil, reason: .disabled)
        }

        guard !isRecording, !isStartingRecording else {
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: candidate, reason: .recording)
                : MeetingPromptDecision(action: .hide, candidate: candidate, reason: .recording)
        }

        guard !isCalendarNotificationVisible else {
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: candidate, reason: .calendarNotificationVisible)
                : MeetingPromptDecision(action: .hide, candidate: candidate, reason: .calendarNotificationVisible)
        }

        guard let candidate else {
            lastCandidateID = nil
            return visiblePromptID == nil
                ? MeetingPromptDecision(action: .none, candidate: nil, reason: .noCandidate)
                : MeetingPromptDecision(action: .hide, candidate: nil, reason: .noCandidate)
        }

        if candidate.id != lastCandidateID {
            lastCandidateID = candidate.id
        }

        if let until = userSuppressedUntilByID[candidate.id], now < until {
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .userDismissedSuppression)
        }

        if let until = autoDismissedUntilByID[candidate.id], now < until {
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .autoDismissedCooldown)
        }

        if visiblePromptID == candidate.id {
            return MeetingPromptDecision(action: .none, candidate: candidate, reason: .promptAlreadyVisible)
        }

        return MeetingPromptDecision(action: .show, candidate: candidate, reason: .eligible)
    }

    func markShown(_ candidate: MeetingCandidate) {
        visiblePromptID = candidate.id
        lastCandidateID = candidate.id
    }

    func markAutoDismissed(_ candidate: MeetingCandidate, now: Date = Date()) {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
        lastCandidateID = candidate.id
        autoDismissedUntilByID[candidate.id] = now.addingTimeInterval(autoDismissCooldown)
    }

    func markUserDismissed(_ candidate: MeetingCandidate, until: Date) {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
        userSuppressedUntilByID[candidate.id] = until
        autoDismissedUntilByID.removeValue(forKey: candidate.id)
    }

    func markClosed(_ candidate: MeetingCandidate) {
        if visiblePromptID == candidate.id { visiblePromptID = nil }
    }

    func resetVisiblePrompt() {
        visiblePromptID = nil
    }

    private func reconcileVisibility(_ visibility: MeetingPromptVisibility) {
        if visibility.isVisible {
            visiblePromptID = visibility.currentPromptID
        } else if visiblePromptID == visibility.currentPromptID || visibility.currentPromptID == nil {
            visiblePromptID = nil
        }
    }

    private func expireUserSuppressions(now: Date) {
        userSuppressedUntilByID = userSuppressedUntilByID.filter { _, until in until > now }
    }

    private func expireAutoDismissSuppressions(now: Date) {
        autoDismissedUntilByID = autoDismissedUntilByID.filter { _, until in until > now }
    }
}
