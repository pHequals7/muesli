import Foundation

// MARK: - Shared Calendar Event Model

struct UnifiedCalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let source: CalendarSource

    enum CalendarSource: String {
        case eventKit
        case googleCalendar
    }
}

// MARK: - Google Calendar API Client

@MainActor
final class GoogleCalendarClient {
    private let auth = GoogleCalendarAuthManager.shared

    private static let baseURL = "https://www.googleapis.com/calendar/v3"

    /// Fetch upcoming events from the user's primary Google Calendar.
    func fetchUpcomingEvents(daysAhead: Int = 7) async throws -> [UnifiedCalendarEvent] {
        let token = try await auth.validAccessToken()

        let now = Date()
        guard let future = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "\(Self.baseURL)/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: now)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: future)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            fputs("[google-cal] API error \(statusCode): \(body.prefix(200))\n", stderr)
            // 401/403 = token revoked or invalid — surface as auth error for auto-signout
            if statusCode == 401 || statusCode == 403 {
                throw GoogleCalendarAuthError.notAuthenticated
            }
            throw GoogleCalendarAuthError.refreshFailed("Calendar API returned \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { parseEvent($0) }
    }

    private func parseEvent(_ item: [String: Any]) -> UnifiedCalendarEvent? {
        guard let id = item["id"] as? String,
              let summary = item["summary"] as? String else { return nil }

        let startDict = item["start"] as? [String: Any] ?? [:]
        let endDict = item["end"] as? [String: Any] ?? [:]

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        dateOnlyFormatter.timeZone = .current

        // Timed events use dateTime, all-day events use date
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool

        if let dateTimeStr = startDict["dateTime"] as? String,
           let start = isoFormatter.date(from: dateTimeStr) {
            startDate = start
            isAllDay = false
            if let endStr = endDict["dateTime"] as? String, let end = isoFormatter.date(from: endStr) {
                endDate = end
            } else {
                endDate = start.addingTimeInterval(3600)
            }
        } else if let dateStr = startDict["date"] as? String,
                  let start = dateOnlyFormatter.date(from: dateStr) {
            startDate = start
            isAllDay = true
            if let endStr = endDict["date"] as? String, let end = dateOnlyFormatter.date(from: endStr) {
                endDate = end
            } else {
                endDate = start.addingTimeInterval(86400)
            }
        } else {
            return nil
        }

        return UnifiedCalendarEvent(
            id: id,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            source: .googleCalendar
        )
    }

    // MARK: - Merge & Deduplicate

    /// Merge EventKit and Google Calendar events, deduplicating by title + start time proximity.
    static func mergeEvents(
        eventKit: [UnifiedCalendarEvent],
        google: [UnifiedCalendarEvent]
    ) -> [UnifiedCalendarEvent] {
        var merged = eventKit

        for gEvent in google {
            let isDuplicate = eventKit.contains { ekEvent in
                ekEvent.title.lowercased() == gEvent.title.lowercased()
                    && abs(ekEvent.startDate.timeIntervalSince(gEvent.startDate)) < 300 // 5 min window
            }
            if !isDuplicate {
                merged.append(gEvent)
            }
        }

        return merged.sorted { $0.startDate < $1.startDate }
    }
}
