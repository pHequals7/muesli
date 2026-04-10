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

    /// Stored sync token from last full fetch — subsequent requests return only changes.
    private var syncToken: String?
    /// Cached events from last fetch, updated incrementally via sync tokens.
    private var cachedEvents: [String: UnifiedCalendarEvent] = [:]

    /// Fetch upcoming events from the user's primary Google Calendar.
    /// Uses sync tokens for incremental updates and handles pagination.
    func fetchUpcomingEvents(daysAhead: Int = 7, isRetry: Bool = false) async throws -> [UnifiedCalendarEvent] {
        var token = try await auth.validAccessToken()

        let isoFormatter = Self.isoFormatter

        var pageToken: String? = nil

        repeat {
            var components = URLComponents(string: "\(Self.baseURL)/calendars/primary/events")!

            if let pageToken {
                components.queryItems = [
                    URLQueryItem(name: "pageToken", value: pageToken),
                ]
            } else if let syncToken {
                components.queryItems = [
                    URLQueryItem(name: "syncToken", value: syncToken),
                ]
            } else {
                let now = Date()
                guard let future = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else { return [] }
                components.queryItems = [
                    URLQueryItem(name: "timeMin", value: isoFormatter.string(from: now)),
                    URLQueryItem(name: "timeMax", value: isoFormatter.string(from: future)),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "maxResults", value: "50"),
                ]
            }

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 410 = sync token expired — retry once with full fetch
            if statusCode == 410 {
                guard !isRetry else {
                    fputs("[google-cal] 410 on full re-fetch, giving up\n", stderr)
                    return Array(cachedEvents.values).sorted { $0.startDate < $1.startDate }
                }
                fputs("[google-cal] sync token expired, performing full re-fetch\n", stderr)
                syncToken = nil
                cachedEvents.removeAll()
                return try await fetchUpcomingEvents(daysAhead: daysAhead, isRetry: true)
            }

            // 401 mid-pagination — refresh token and retry this page once
            if statusCode == 401 && !isRetry {
                token = try await auth.validAccessToken()
                continue
            }

            guard statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                fputs("[google-cal] API error \(statusCode): \(body.prefix(200))\n", stderr)
                if statusCode == 401 || statusCode == 403 {
                    throw GoogleCalendarAuthError.notAuthenticated
                }
                throw GoogleCalendarAuthError.refreshFailed("Calendar API returned \(statusCode)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                break
            }

            if let items = json["items"] as? [[String: Any]] {
                for item in items {
                    guard let id = item["id"] as? String else { continue }
                    if item["status"] as? String == "cancelled" {
                        cachedEvents.removeValue(forKey: id)
                        continue
                    }
                    if let event = parseEvent(item) {
                        cachedEvents[id] = event
                    }
                }
            }

            // nextPageToken = more pages to fetch; nextSyncToken = done, use for incremental
            if let nextPage = json["nextPageToken"] as? String {
                pageToken = nextPage
            } else {
                pageToken = nil
                if let newSyncToken = json["nextSyncToken"] as? String {
                    syncToken = newSyncToken
                }
            }
        } while pageToken != nil

        let now = Date()
        let events = cachedEvents.values.filter { $0.endDate > now }
        return events.sorted { $0.startDate < $1.startDate }
    }

    /// Clear cached state (call on sign-out).
    func resetSync() {
        syncToken = nil
        cachedEvents.removeAll()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private func parseEvent(_ item: [String: Any]) -> UnifiedCalendarEvent? {
        guard let id = item["id"] as? String,
              let summary = item["summary"] as? String else { return nil }

        let startDict = item["start"] as? [String: Any] ?? [:]
        let endDict = item["end"] as? [String: Any] ?? [:]

        let isoFormatter = Self.isoFormatter
        let dateOnlyFormatter = Self.dateOnlyFormatter

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
                    && abs(ekEvent.startDate.timeIntervalSince(gEvent.startDate)) < 300
            }
            if !isDuplicate {
                merged.append(gEvent)
            }
        }

        return merged.sorted { $0.startDate < $1.startDate }
    }
}
