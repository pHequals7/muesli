# ADR 0001 — Add `AutoCaptureCoordinator` as a pure listener on top of existing detection

- Date: 2026-05-13
- Status: Accepted

## Context

The fork already ships a multi-signal `MeetingDetector` driven by
`MeetingMonitor`. Detection currently powers a user-facing notification that
prompts to start recording. We want opt-in **auto-start** of meeting recording
without re-architecting the detector or the monitor, both of which the
maintainer has tuned for stability.

The execution prompt asks us to:

- Avoid modifying `MeetingDetector.swift`, `MeetingSession.swift`, or
  `MeetingMonitor.swift` beyond — if absolutely required — a single observer
  hook.
- Implement a state machine matching `tickets/architecture.md` §5.
- Keep auto-capture self-contained under `AutoCapture/`.

## Decision

We introduce a new `@MainActor final class AutoCaptureCoordinator` that:

- Owns only the auto-capture state machine; allocates no system resources.
- Receives signals as a generic `AutoCaptureSignal` value type that
  `MuesliController` constructs from the existing `MeetingCandidate?` already
  delivered by `MeetingMonitor.onPromptCandidateChanged`.
- Drives the existing public `MuesliController.startMeetingRecording(title:)`
  via an injected closure, so the coordinator never reaches into recording
  internals.
- Persists user acknowledgements through an injected config-writer closure
  that calls `MuesliController.updateConfig`.

`MeetingMonitor.swift`, `MeetingDetector.swift`, and `MeetingSession.swift`
remain unchanged. We **chain** into `MeetingMonitor`'s existing
`onPromptCandidateChanged` closure in `MuesliController.start()` so both the
notification UI and the coordinator receive each candidate event. No new
public surface was added to any of the existing detection types.

## Consequences

- Subscribing through the existing callback path costs effectively nothing and
  keeps the detection pipeline canonical.
- The coordinator depends on the public type `MeetingCandidate` (via the
  signal-construction site inside `MuesliController`) but is itself testable
  with a plain-value `AutoCaptureSignal`, so unit tests run with no AppKit
  dependencies.
- A future phase that needs richer evidence (e.g. v3 extension messages) can
  add more fields to `AutoCaptureSignal` without disturbing the upstream
  detector.
- Tests for the coordinator live inside the existing `MuesliTests` target
  under `Tests/MuesliTests/AutoCapture/`. The prompt suggested a separate
  `Tests/AutoCaptureTests/` directory but the global constraint of not
  editing `Package.swift` forbids adding a new test target. The chosen
  layout still keeps the tests visually grouped without changing the build
  graph.
