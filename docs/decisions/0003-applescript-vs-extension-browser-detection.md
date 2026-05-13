# ADR 0003 — Use AppleScript URL polling (v1) for browser meeting detection while waiting on the extension (v3)

- Date: 2026-05-13
- Status: Accepted

## Context

v0 covers native meeting apps and the subset of browser meetings the existing
`MeetingActivitySnapshot.browserURL` already surfaces (via the Accessibility
`kAXDocumentAttribute`). That snapshot does not see URLs in every browser /
profile / window combination. Some examples that fall through the AX path:

- Chrome PWAs and tabs that the AX bridge fails to expose the document URL for.
- Browsers running in profiles or private windows where AX returns nil.
- Background browser windows that aren't the frontmost AX target at the moment
  the snapshot is taken.

We need a way to read the active tab URL for those cases. The architecture
document (`tickets/architecture.md` §4.4) calls out two follow-on routes:

- **v1: AppleScript URL polling.** Drives `tell application id "<bundle>"` via
  `NSAppleScript`, reads `URL of active tab of front window`. Gated on macOS
  Automation permission per browser.
- **v3: Native messaging + MV3 extension.** A long-running stdio host
  cooperates with a Muesli-authored Chromium extension. The extension reports
  `call_started` events directly from the meeting DOM. Higher signal, lower
  latency, no AppleScript / Automation surface.

The longer-term plan is v3. v1 buys us coverage today for the common
"browser-in-meeting" path without waiting for the extension to ship.

## Decision

Land v1 with AppleScript URL polling, gated on:

1. **Per-browser opt-in flags** in `AutoCaptureConfig.browserUrlPolling`. All
   off by default — upgrading from v0 changes nothing.
2. **Mic-ownership trigger.** A 1Hz watchdog asks
   `AudioProcessAttributionCollector.activeInputProcesses()` whether a
   configured browser is using a microphone input device. AppleScript only
   runs once we observe that. As soon as the browser releases the mic, the
   poller drops back to the watchdog — zero AppleScript invocations otherwise.
3. **macOS Automation permission.** Probed via
   `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded == false`.
   A denial is sticky for the affected bundle ID until the user opts back in
   through Settings → Privacy & Security → Automation; the Settings pane
   shows a persistent banner explaining what's broken.
4. **0.5s polling cadence** while a configured browser owns the mic. We
   considered 1Hz but the lower cadence lost real meetings that auto-paused
   the mic for 1–2s on join. 0.5s catches them and still emits a single
   `AutoCaptureSignal` per meeting because the poller deduplicates by
   normalised URL.

The poller emits to the existing v0 `AutoCaptureCoordinator.handle(_:)`. The
coordinator treats the resulting signal identically to a v0 tier-C detection,
so the state machine, first-run modal, start-delay, and Focus gating all
behave exactly as they do for the native-app paths.

## Rationale for choosing AppleScript over alternatives in the v1 window

| Option | Why we did not pick it for v1 |
|---|---|
| Extension (v3 plan) | Real surface area: extension manifest, native messaging host, signed updates, per-browser install. Not landable in a single phase. |
| `kAXDocumentAttribute` alone | Already used by v0 and known to miss the cases v1 targets. Not a separate channel. |
| ScriptingBridge / SBApplication | Wraps the same AppleEvents pipeline. Same permission surface, more Objective-C glue, no extra capability. |
| `osascript` subprocess | Spawns a process per poll. Slower, harder to instrument, no clear advantage over `NSAppleScript`. The constraints in `tickets/prompt-v1.md` explicitly forbid this. |
| Browser Web Authentication / `chrome://` URLs | Browser-specific, fragile, no cross-browser API. Same end result as AppleScript but more brittle. |

## Permission probe — non-prompting check

`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded == false` is the
only macOS API that answers "does this AppleScript target have permission"
without surfacing a prompt. It returns:

- `noErr` → granted.
- `errAEEventNotPermitted` (-1743) → denied (user said no in System Settings).
- `errAEEventWouldRequireUserConsent` (-1744) → not yet determined.
- `procNotFound` (-600) → target app not running.

For the onboarding step's `Request` button and for the lazy first-AppleScript
path, we call the same probe with `askUserIfNeeded == true`, which surfaces
the system prompt for `.notDetermined`. The setting is **per source / target
bundle ID pair**, so the answer covers any AppleScript verb we might later
send (we pass `typeWildCard` for both class and ID).

If a future macOS version removes the non-prompting variant, the fallback is
to render the onboarding step as informational only and rely on lazy
first-run prompts triggered by the first poll.

## Consequences

- **Net new surface.** One module (`AutoCapture/BrowserURLPoller.swift`), one
  permission probe (`AutoCapture/AutomationPermission.swift`), one onboarding
  step. No changes to `MeetingDetector.swift`, `MeetingMonitor.swift`,
  `MeetingSession.swift`, or `MuesliController.swift`. The coordinator owns
  the poller and the production factory bootstraps it from
  `AutoCaptureCoordinator.start()`.
- **AppleScript Automation prompts.** The first time the user enables a
  browser, macOS surfaces a system Automation prompt. Settings shows a
  persistent banner when the answer comes back as `.denied`.
- **Latency floor.** Browser mic acquisition → recording start is bounded by
  `auto_capture.start_delay_seconds + 0.5s + first-AppleScript-roundtrip`.
  Empirically that's ≤ 6s, which matches the v0 native-app path.
- **Replacement path is clean.** v3's `NativeMessagingHost` will pre-empt the
  poller by emitting `AutoCaptureSignal` from the extension via `stdin`. The
  coordinator does not care which path produces the signal, so the poller
  becomes a fallback that the user can leave on or disable per browser.

## Alternatives considered and rejected for v1

- **Combining v1 and v3 in one phase.** Too large; would either ship an
  unsigned extension or block the phase on the Chrome Web Store review cycle.
- **Auto-stop heuristics in v1.** Out of scope per the ticket. Belongs with
  v3 because the extension can report `call_ended` directly.
- **Polling without the mic-ownership trigger.** Constant AppleScript chatter
  even when no meeting is in progress. Wastes Automation prompts and battery.
