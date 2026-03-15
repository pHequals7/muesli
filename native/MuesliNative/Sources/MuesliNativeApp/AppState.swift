import Foundation
import Observation

enum DashboardTab: String, CaseIterable {
    case dictations
    case meetings
    case shortcuts
    case settings
}

@MainActor
@Observable
final class AppState {
    // Dashboard data
    var dictationRows: [DictationRecord] = []
    var meetingRows: [MeetingRecord] = []
    var selectedMeetingID: Int64?
    var dictationStats: DictationStats = DictationStats(
        totalWords: 0, totalSessions: 0, averageWordsPerSession: 0,
        averageWPM: 0, currentStreakDays: 0, longestStreakDays: 0
    )
    var meetingStats: MeetingStats = MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)

    // Config-driven state
    var selectedBackend: BackendOption = .whisper
    var selectedMeetingSummaryBackend: MeetingSummaryBackendOption = .openAI
    var config: AppConfig = AppConfig()

    // Live status
    var isMeetingRecording: Bool = false

    // Navigation
    var selectedTab: DashboardTab = .dictations

    // Computed
    var selectedMeeting: MeetingRecord? {
        guard let id = selectedMeetingID else { return meetingRows.first }
        return meetingRows.first(where: { $0.id == id })
    }
}
