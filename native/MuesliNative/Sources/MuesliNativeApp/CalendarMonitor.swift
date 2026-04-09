import EventKit
import Foundation
import MuesliCore

struct UpcomingMeetingEvent {
    let id: String
    let title: String
    let startDate: Date
}

final class CalendarMonitor {
    private let store = EKEventStore()
    private var timer: Timer?
    private var notifiedEvents = Set<String>()
    var onMeetingSoon: ((UpcomingMeetingEvent) -> Void)?

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard granted, let self else { return }
            DispatchQueue.main.async {
                self.checkMeetings()
                self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.checkMeetings()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Returns the current calendar event if one is happening right now.
    func currentEvent() -> UpcomingMeetingEvent? {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(60), calendars: nil)
        let events = store.events(matching: predicate)
        for event in events {
            guard let startDate = event.startDate, let endDate = event.endDate else { continue }
            if startDate <= now && endDate > now {
                return UpcomingMeetingEvent(
                    id: event.eventIdentifier ?? "",
                    title: event.title ?? "Meeting",
                    startDate: startDate
                )
            }
        }
        return nil
    }

    /// Returns the current or recently started event (within 15 minutes)
    /// for meeting detection. Prefers currently active events over nearby ones.
    func currentOrNearbyEvent() -> CalendarEventContext? {
        let now = Date()
        let searchStart = now.addingTimeInterval(-15 * 60)
        let searchEnd = now.addingTimeInterval(5 * 60)
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let events = store.events(matching: predicate)

        var nearby: CalendarEventContext?
        for event in events {
            guard let startDate = event.startDate, let endDate = event.endDate else { continue }
            let ctx = CalendarEventContext(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting"
            )
            // Currently active — return immediately
            if startDate <= now && endDate > now {
                return ctx
            }
            // Recently started (within 15 min) or about to start (within 5 min)
            if nearby == nil {
                nearby = ctx
            }
        }
        return nearby
    }

    /// Returns upcoming events from the local macOS calendar (EventKit) for the next N days.
    func upcomingEvents(daysAhead: Int = 7) -> [UnifiedCalendarEvent] {
        let now = Date()
        guard let future = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: future, calendars: nil)
        let events = store.events(matching: predicate)
        return events.compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            return UnifiedCalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting",
                startDate: startDate,
                endDate: endDate,
                isAllDay: event.isAllDay,
                source: .eventKit
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    private func checkMeetings() {
        let now = Date()
        let end = now.addingTimeInterval(5 * 60)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        for event in events {
            guard let eventID = event.eventIdentifier, !notifiedEvents.contains(eventID) else {
                continue
            }
            notifiedEvents.insert(eventID)
            onMeetingSoon?(UpcomingMeetingEvent(
                id: eventID,
                title: event.title ?? "Meeting",
                startDate: event.startDate
            ))
        }
    }
}
