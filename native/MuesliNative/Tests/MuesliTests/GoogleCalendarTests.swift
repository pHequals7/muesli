import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Google Calendar integration")
@MainActor
struct GoogleCalendarTests {

    // MARK: - Credentials parsing

    @Test("loads credentials from valid JSON")
    func loadsValidCredentials() throws {
        let json = """
        {"client_id": "test-id.apps.googleusercontent.com", "client_secret": "test-secret"}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-creds-\(UUID()).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let clientId = parsed["client_id"] as? String
        let clientSecret = parsed["client_secret"] as? String

        #expect(clientId == "test-id.apps.googleusercontent.com")
        #expect(clientSecret == "test-secret")
    }

    @Test("verified defaults to false when missing from JSON")
    func verifiedDefaultsFalse() throws {
        let json = """
        {"client_id": "id", "client_secret": "secret"}
        """
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let verified = parsed["verified"] as? Bool ?? false
        #expect(verified == false)
    }

    @Test("verified reads true from JSON")
    func verifiedReadsTrue() throws {
        let json = """
        {"client_id": "id", "client_secret": "secret", "verified": true}
        """
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let verified = parsed["verified"] as? Bool ?? false
        #expect(verified == true)
    }

    // MARK: - Event JSON parsing

    @Test("parses timed event from Google Calendar API response")
    func parsesTimedEvent() {
        let item: [String: Any] = [
            "id": "event123",
            "summary": "Sprint Planning",
            "start": ["dateTime": "2026-04-10T14:00:00+05:30"],
            "end": ["dateTime": "2026-04-10T15:00:00+05:30"],
        ]

        let event = GoogleCalendarClient().parseEvent(item)
        #expect(event != nil)
        #expect(event?.id == "event123")
        #expect(event?.title == "Sprint Planning")
        #expect(event?.isAllDay == false)
        #expect(event?.source == .googleCalendar)
    }

    @Test("parses all-day event from Google Calendar API response")
    func parsesAllDayEvent() {
        let item: [String: Any] = [
            "id": "allday1",
            "summary": "Company Holiday",
            "start": ["date": "2026-04-10"],
            "end": ["date": "2026-04-11"],
        ]

        let event = GoogleCalendarClient().parseEvent(item)
        #expect(event != nil)
        #expect(event?.isAllDay == true)
        #expect(event?.title == "Company Holiday")
    }

    @Test("returns nil for event missing summary")
    func returnsNilMissingSummary() {
        let item: [String: Any] = [
            "id": "no-title",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]

        #expect(GoogleCalendarClient().parseEvent(item) == nil)
    }

    @Test("returns nil for event missing id")
    func returnsNilMissingId() {
        let item: [String: Any] = [
            "summary": "Test",
            "start": ["dateTime": "2026-04-10T14:00:00Z"],
            "end": ["dateTime": "2026-04-10T15:00:00Z"],
        ]

        #expect(GoogleCalendarClient().parseEvent(item) == nil)
    }

    // MARK: - Merge & dedup

    @Test("merges EventKit and Google events without duplicates")
    func mergesWithoutDuplicates() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Standup", startDate: date("2026-04-10T09:00:00Z"), endDate: date("2026-04-10T09:15:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Design Review", startDate: date("2026-04-10T10:00:00Z"), endDate: date("2026-04-10T11:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 2)
        #expect(merged[0].title == "Standup")
        #expect(merged[1].title == "Design Review")
    }

    @Test("deduplicates events with same title and close start time")
    func deduplicatesByTitleAndTime() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Sprint Planning", startDate: date("2026-04-10T14:00:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Sprint Planning", startDate: date("2026-04-10T14:02:00Z"), endDate: date("2026-04-10T15:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 1)
        #expect(merged[0].source == .eventKit)
    }

    @Test("keeps events with same title but different times")
    func keepsSameTitleDifferentTimes() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Standup", startDate: date("2026-04-10T09:00:00Z"), endDate: date("2026-04-10T09:15:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Standup", startDate: date("2026-04-11T09:00:00Z"), endDate: date("2026-04-11T09:15:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged.count == 2)
    }

    @Test("merged events are sorted by start date")
    func mergedSortedByStartDate() {
        let ek = [
            UnifiedCalendarEvent(id: "ek1", title: "Late", startDate: date("2026-04-10T16:00:00Z"), endDate: date("2026-04-10T17:00:00Z"), isAllDay: false, source: .eventKit),
        ]
        let google = [
            UnifiedCalendarEvent(id: "g1", title: "Early", startDate: date("2026-04-10T08:00:00Z"), endDate: date("2026-04-10T09:00:00Z"), isAllDay: false, source: .googleCalendar),
        ]

        let merged = GoogleCalendarClient.mergeEvents(eventKit: ek, google: google)
        #expect(merged[0].title == "Early")
        #expect(merged[1].title == "Late")
    }

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

}
