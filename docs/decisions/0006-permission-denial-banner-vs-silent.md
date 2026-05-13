# ADR 0006 — Auto-Capture defaults: pause during Focus, fail silently on coordinator denial

- Date: 2026-05-13
- Status: Accepted

## Context

Auto-Capture can refuse to start in several scenarios:

- `MuesliController.startMeetingRecording` returns a failure (e.g. mic or
  screen-recording permission missing).
- macOS Focus / Do Not Disturb is active and the user has chosen to suppress
  auto-capture in that mode.
- The bundle ID is not in `allowed_app_bundle_ids`.

We considered two ways to surface these refusals:

1. **Persistent banner in Settings**: explicit, but visually heavy and risks
   nagging users for transient states.
2. **Silent fail with diagnostic surface**: nothing on screen, but the CLI
   `auto-capture status` subcommand and `MuesliLog` carry the reason.

## Decision

- **Silent fail** is the v0 default for all coordinator-internal denials
  (Focus, app not allowed, strict-calendar mismatch). Users who want to
  diagnose can run `muesli-cli auto-capture status`. Each denial is logged
  via `Logger(subsystem: "com.muesli.native", category: "AutoCapture")`.
- **`disable_during_focus` defaults to `true`.** It is the most
  privacy-respecting default for share-desk situations and matches user
  expectations from macOS itself. Users can flip it off in settings.
- Recording failures (the closure returning `false`) transition to `idle`
  and rely on the existing `MuesliController` alert pipeline for the
  user-visible error — we do not stack a second auto-capture-specific
  alert.

## Consequences

- The Settings pane stays calm at rest; the toggle is the only thing that
  changes when state changes.
- Diagnosing "why didn't auto-capture fire?" requires the CLI subcommand or
  Console.app log filtering. This is acceptable for v0 (alpha-ish feature);
  v1 may add an inline status row in the pane.
- The Focus pause is conservative: if Apple ever exposes
  `INFocusStatusCenter` without permission cost, we can wire it without
  changing the user-facing toggle.
