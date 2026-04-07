import Foundation

public enum MeetingNotesState: String, Codable, Sendable {
    case missing
    case rawTranscriptFallback = "raw_transcript_fallback"
    case structuredNotes = "structured_notes"
}

public enum MeetingTemplateKind: String, Codable, Sendable {
    case auto
    case builtin
    case custom
}

public enum MeetingRecordingSavePolicy: String, Codable, CaseIterable, Sendable {
    case never
    case prompt
    case always
}

public struct DictationRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let timestamp: String
    public let durationSeconds: Double
    public let rawText: String
    public let appContext: String
    public let wordCount: Int

    public init(id: Int64, timestamp: String, durationSeconds: Double, rawText: String, appContext: String, wordCount: Int) {
        self.id = id
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.appContext = appContext
        self.wordCount = wordCount
    }
}

public struct MeetingRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let title: String
    public let startTime: String
    public let durationSeconds: Double
    public let rawTranscript: String
    public let formattedNotes: String
    public let wordCount: Int
    public let folderID: Int64?
    public let calendarEventID: String?
    public let micAudioPath: String?
    public let systemAudioPath: String?
    public let savedRecordingPath: String?
    public let selectedTemplateID: String?
    public let selectedTemplateName: String?
    public let selectedTemplateKind: MeetingTemplateKind?
    public let selectedTemplatePrompt: String?

    public init(
        id: Int64,
        title: String,
        startTime: String,
        durationSeconds: Double,
        rawTranscript: String,
        formattedNotes: String,
        wordCount: Int,
        folderID: Int64?,
        calendarEventID: String? = nil,
        micAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        savedRecordingPath: String? = nil,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.formattedNotes = formattedNotes
        self.wordCount = wordCount
        self.folderID = folderID
        self.calendarEventID = calendarEventID
        self.micAudioPath = micAudioPath
        self.systemAudioPath = systemAudioPath
        self.savedRecordingPath = savedRecordingPath
        self.selectedTemplateID = selectedTemplateID
        self.selectedTemplateName = selectedTemplateName
        self.selectedTemplateKind = selectedTemplateKind
        self.selectedTemplatePrompt = selectedTemplatePrompt
    }

    public var notesState: MeetingNotesState {
        let trimmed = formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }
        let normalized = trimmed.lowercased()
        if normalized == "## raw transcript" || normalized.hasPrefix("## raw transcript\n") {
            return .rawTranscriptFallback
        }
        return .structuredNotes
    }

    public var appliedTemplateID: String {
        let trimmed = selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "auto" : trimmed
    }

    public var appliedTemplateName: String {
        let trimmed = selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Auto" : trimmed
    }

    public var appliedTemplateKind: MeetingTemplateKind {
        selectedTemplateKind ?? .auto
    }
}

public struct MeetingFolder: Identifiable, Codable, Sendable {
    public let id: Int64
    public var name: String
    public var sortOrder: Int
    public let createdAt: String

    public init(id: Int64, name: String, sortOrder: Int = 0, createdAt: String) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public struct DictationStats: Codable, Sendable {
    public let totalWords: Int
    public let totalSessions: Int
    public let averageWordsPerSession: Double
    public let averageWPM: Double
    public let currentStreakDays: Int
    public let longestStreakDays: Int

    public init(totalWords: Int, totalSessions: Int, averageWordsPerSession: Double, averageWPM: Double, currentStreakDays: Int, longestStreakDays: Int) {
        self.totalWords = totalWords
        self.totalSessions = totalSessions
        self.averageWordsPerSession = averageWordsPerSession
        self.averageWPM = averageWPM
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

public struct MeetingStats: Codable, Sendable {
    public let totalWords: Int
    public let totalMeetings: Int
    public let averageWPM: Double

    public init(totalWords: Int, totalMeetings: Int, averageWPM: Double) {
        self.totalWords = totalWords
        self.totalMeetings = totalMeetings
        self.averageWPM = averageWPM
    }
}
