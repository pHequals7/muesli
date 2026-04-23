import Foundation

enum MeetingTerminationState: Equatable {
    case none
    case starting
    case recording
    case processing
}

enum MeetingTerminationPolicy {
    static func state(
        isStarting: Bool,
        hasActiveSession: Bool,
        isRecording: Bool,
        isStopping: Bool
    ) -> MeetingTerminationState {
        if isStopping {
            return .processing
        }
        if isStarting {
            return .starting
        }
        if hasActiveSession {
            return isRecording ? .recording : .processing
        }
        return .none
    }
}
