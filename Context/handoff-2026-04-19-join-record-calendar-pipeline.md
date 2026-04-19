# Context Handover — Join & Record, unified calendar notification pipeline

**Session Date:** 2026-04-18 to 2026-04-19
**Repository:** muesli
**Branch:** main (PR #54 merged via squash)

---

## What Got Done

### Unified Calendar Notification Pipeline
- Removed redundant `CalendarMonitor.checkMeetings()` that raced with `checkUpcomingCalendarNotifications()`, causing nil meetingURL poisoning of the dedup set
- Single notification path: `checkUpcomingCalendarNotifications()` in MuesliController
- Event-driven via `EKEventStoreChangedNotification` — instant notifications for local/synced calendar changes, immune to App Nap timer suspension
- 60s fallback timer for Google Calendar OAuth polling (sync token) and time-based notification window checks
- Composite dedup key `id|startDate` — rescheduled events generate fresh notifications
- Per-event timer dictionary `[String: Timer]` — concurrent events no longer drop each other's "starting now" notification

### Join & Record Feature
- Meeting URL extraction from EventKit (url/location/notes regex) and Google Calendar API (hangoutLink/conferenceData)
- Split button UX: "Join & Record" + chevron dropdown with "Join Only" / "Record Only"
- Platform icons for Zoom (PNG), Google Meet (PNG) in notification panel
- `joinAndRecord()` / `joinOnly()` single entry points on MuesliController — used by both notification panel and Coming Up section
- "Join & Record" button in Coming Up section (hidden during active recording)
- `mergeEvents` preserves Google Calendar meetingURL when EventKit duplicate has none

### Notification Reliability Fixes
- `onClose` lifecycle fix: nil-before-close() in `show()` prevents old panel's callback from resetting `isShowingCalendarNotification`
- `isShowingCalendarNotification` guard added to `updateMeetingNotificationVisibility()` — detection notifications can't replace visible calendar notification
- Mic/camera detection suppressed for calendar event duration after Join Only / Dismiss
- Notification on correct monitor (mouse cursor screen detection)
- Notification above fullscreen apps (`CGShieldingWindowLevel() + 1`)
- Fade-in animation restored on notification panel
- `NSApp.activate` before `runModal()` for background app modal dialogs
- Fallback recovery when `activeMeetingSession` is nil (indicator stuck fix)

### Marauder's Map Coordination
- `onCountdownFinished` passes `(id: String, title: String)` tuple — ID-based event lookup
- Cancels Path 1's "starting now" timer by event ID prefix
- Calls `showMeetingStartingNowNotification()` instead of duplicating (fixes dismissAfter 30 vs 15 inconsistency)

### Other
- Model card reorder: Parakeet -> Whisper -> Cohere Transcribe
- Debug logging cleanup: removed CalendarMonitor.log file system, indicator fputs, meeting title fputs
- "Add Google to macOS Calendar for real-time sync" link in Coming Up section (opens System Settings > Internet Accounts)
- `@MainActor` on startup Task in `startCalendarMonitoring`
- `handleUpcomingMeeting` uses ID-only lookup (removed title fallback for duplicate-titled events)

## Known Issue — Not Yet Fixed

**"Meeting starting now" timer fires after Join Only / Dismiss**

`handleUpcomingMeeting` schedules a `meetingStartingNowTimers[key]` timer, but the `onJoinOnly` and `onDismiss` callbacks don't cancel it. The timer key is scoped to `checkUpcomingCalendarNotifications` and not passed to `handleUpcomingMeeting`. Result: after clicking "Join Only" or "Dismiss", a redundant "Meeting starting now" notification fires at event start time.

Fix: pass the notification key into `handleUpcomingMeeting` so the callbacks can cancel it.

## macOS 26 Timer Suspension Discovery

**All timer mechanisms are suspended in LSUIElement apps on macOS 26:**
- `Timer.scheduledTimer` — never fires after startup
- `DispatchSourceTimer` — never fires
- `Task.sleep` — never wakes
- `Thread.sleep` — never wakes
- `DispatchQueue.asyncAfter` — one-shot works during startup, repeating chains don't
- POSIX `nanosleep` — never wakes

**What works:**
- `NotificationCenter.default` observers (e.g. `EKEventStoreChangedNotification`) — system IPC, immune to App Nap
- One-shot `DispatchQueue.main.asyncAfter` during startup sequence
- Timers work when the binary is launched directly from terminal (not via `open`)

**Root cause:** macOS 26 aggressively naps LSUIElement (menu bar) apps. Granola, Wispr Flow, and Handy all run without `LSUIElement` (permanent Dock icon) to avoid this.

**Current approach:** `EKEventStoreChangedNotification` for EventKit changes (reliable) + 60s `Timer` for Google Calendar OAuth polling (may get napped). Users with Google Calendar synced to macOS Calendar get reliable notifications via EventKit. OAuth-only users depend on the 60s timer.

**Future options:**
1. Remove `LSUIElement = true` — makes all timers reliable, adds permanent Dock icon
2. `NSApp.setActivationPolicy(.accessory)` toggle — but Apple docs say `.accessory` is equivalent to `LSUIElement`, so timers would get napped again in that mode
3. Accept limitation for OAuth-only users — guide them to add Google to macOS Calendar

## Key Decisions

- **EKEventStoreChangedNotification over polling** — push-based, immune to App Nap, instant
- **Keep LSUIElement for now** — Dock icon UX concern outweighs timer reliability for most users
- **Google Calendar push notifications impossible without server** — webhooks require publicly accessible HTTPS endpoint
- **Per-event timer dictionary over single timer** — prevents concurrent event notification loss
- **joinAndRecord/joinOnly as single entry points** — keeps notification panel and Coming Up section in sync

## Files Changed (PR #54)

- `CalendarMonitor.swift` — EKEventStoreChanged observer, removed checkMeetings/notifiedEvents/onMeetingSoon/logFile/log
- `MuesliController.swift` — unified pipeline, event-driven monitoring, per-event timers, joinAndRecord/joinOnly, suppression, onClose lifecycle
- `MeetingNotificationController.swift` — split button, platform icons, onClose fix, fade-in, mouse screen
- `GoogleCalendarClient.swift` — meetingURL on UnifiedCalendarEvent, mergeEvents URL backfill
- `MaraudersMapCountdownController.swift` — (id, title) tuple callback
- `MeetingsView.swift` — Join & Record button, macOS Calendar sync link
- `FloatingIndicatorController.swift` — removed debug fputs
- `Models.swift` / `ModelsView.swift` — model card reorder
- `GoogleCalendarTests.swift` — 6 new tests
- `build_native_app.sh` — zoom-app.png, google-meet.png bundling
- `AppDelegate.swift` — no changes (reverted beginActivity diagnostic)
- `assets/zoom-app.png` — new, converted from SVG
