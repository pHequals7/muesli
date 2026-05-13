# ADR 0002 — Keep `autoRecordMeetings` (calendar path) unchanged

- Date: 2026-05-13
- Status: Accepted

## Context

`AppConfig.autoRecordMeetings` already auto-starts recording when a calendar
event fires (`MuesliController.swift` around the `handleUpcomingMeeting`
handler near line 4167). It's user-facing, opt-in, and the maintainer has
fixed bugs against it. Auto-Capture v0 introduces an overlapping concept:
detector-driven auto-start.

We considered replacing `autoRecordMeetings` with the new coordinator's
"require calendar match" mode, but the two paths cover different intents:

- `autoRecordMeetings` fires from calendar **even when no detection event
  occurs** (e.g. headset call without camera). It runs without needing a
  detector signal.
- Auto-Capture v0 fires from detector events. It can be combined with
  calendar via the strict-mode toggle but does not subsume calendar-only
  starts.

## Decision

Leave `autoRecordMeetings` and its calendar-driven start path unchanged.
Auto-Capture v0 is an *additional* path:

- `auto_record_meetings` stays in `AppConfig`. Its existing handler runs
  before any auto-capture logic.
- The new coordinator short-circuits if a meeting is already recording
  (`isRecordingNow()`), so the calendar path always wins when both could fire
  at once.
- Settings UI keeps the existing "Auto-record calendar meetings" toggle in
  the Meetings pane; the new Auto-Capture pane is separate.

## Consequences

- Users who already rely on the calendar auto-start see zero behavioural
  change.
- We never need to migrate or interpret existing `auto_record_meetings`
  values — there is no overlap to reconcile.
- A future v0.x or v1 could deprecate `autoRecordMeetings` once detector
  coverage feels equivalent, but that decision is explicitly deferred.
