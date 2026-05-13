# ADR 0005 — First-run modal cadence is once per bundle ID

- Date: 2026-05-13
- Status: Accepted

## Context

Auto-Capture starts recording without explicit user action. A user who turns
on the master toggle and then walks away from their desk while Zoom is
running could otherwise produce a runaway recording. We need a hard
guardrail on first activation without turning into a nag.

Options considered:

1. Always show the modal (annoying; defeats the point of auto-capture).
2. Show once globally (silently auto-captures every new app forever).
3. Show once per detected bundle ID — strikes a balance: each new app needs
   a single approval, then it's silent.

## Decision

- First-run modal is shown **once per detected bundle ID**, persisted to
  `auto_capture.acknowledged_app_bundle_ids` in `config.json`.
- The modal has three primary outcomes:
  - **Start Recording** — proceeds; optionally writes the bundle ID into the
    acknowledged set when "Don't ask again for <app>" is ticked.
  - **Not Now** — declines; optionally writes the bundle ID into the
    acknowledged set so the user is not pestered again.
  - **Timeout** — after `AutoCaptureConfig.confirmationTimeoutSeconds = 30`
    seconds, the coordinator treats the modal as declined.
- A "Reset first-run prompts" link in the Auto-Capture settings pane clears
  `acknowledged_app_bundle_ids` so the user can re-confirm.

## Consequences

- New users see exactly one prompt per app on first activation, then never
  again per app — close to the iOS pattern users already know.
- Tying acknowledgement to bundle ID (rather than per session) means a user
  who later turns off the master toggle and re-enables it keeps their
  approvals. This is intentional: the user explicitly opted in, so we do not
  ask twice for the same app unless they reset.
- 30 seconds is short enough that an unattended desk does not stall a
  recording forever; long enough that users coming back from a coffee can
  still react.
