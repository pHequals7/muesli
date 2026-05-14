# ADR 0009 — CoreAudio HAL mic-release listener for browser/PWA auto-stop (v2.1)

- Date: 2026-05-14
- Status: Accepted

## Context

v0/v1/v2 of Auto-Capture all only auto-*start* a recording — the user still has
to hit Stop manually. The most common bug report is: "I joined Teams Web in
Chrome, Muesli started recording automatically, I left the call, Muesli kept
recording until I noticed." We need an auto-stop signal for browser-hosted and
PWA-hosted meetings.

Three concrete options were on the table.

## Options considered

### 1. Per-tab URL / title polling

Continue polling AppleScript and treat a flip away from a meeting URL (or a
title flip from "X (3) — Microsoft Teams" → "Microsoft Teams") as an end-of-call
signal. Rejected per maintainer instruction: tab/window enumeration via
AppleScript is fragile across browser versions, fights with the v1 Automation
permission story, and gives us no signal at all for tabs that keep the URL but
release the mic (e.g., Meet in a pinned tab post-leave). It's also a steady
drumbeat of AppleScript invocations during every call — exactly the cost the v1
mic-ownership gate was designed to eliminate.

### 2. Injected browser extension

A Muesli-authored MV3 extension that reports `call_ended` from the meeting DOM.
This is the v3 plan and is the long-term right answer. Rejected as the v2.1
mechanism per maintainer instruction because the surface area (extension
manifest, native messaging host, per-browser install, Chrome Web Store review
cycle, Safari Web Extension target) is too large for a stop-detection fix; we
need something landable today.

### 3. CoreAudio HAL listener on the browser's per-process AudioObject

**Accepted.** The CoreAudio HAL exposes a per-process AudioObject for every
process that touches an input or output device. The relevant properties are:

- `kAudioHardwarePropertyTranslatePIDToProcessObject` — get a per-process
  AudioObject from a PID (macOS 14.2+, already available on Muesli's target).
- `kAudioProcessPropertyIsRunningInput` — whether the process is currently
  capturing from any input device. Listenable via
  `AudioObjectAddPropertyListenerBlock`.
- `kAudioHardwarePropertyProcessObjectList` — the list of process objects on
  `kAudioObjectSystemObject`. Listenable so we can reattach when a process
  AudioObject is created or destroyed (process restart, profile switch, etc.).

The exact same primitives back the existing
`AudioProcessAttributionCollector.activeInputProcesses()` that v0 and v1 rely
on, so we're not introducing a new system surface — we're subscribing to a
notification channel on data we already poll.

## Decision

Add `BrowserMicReleaseMonitor` under `AutoCapture/`. When the coordinator
auto-starts a recording for a browser-family bundle ID (or a PWA whose parent
process is one of those bundles — see "PWA roll-up" below), the coordinator
calls `monitor.beginWatching(bundleID:)`. The monitor:

1. Resolves the bundle ID to a *parent browser* bundle ID via
   `parentBrowserBundleID(for:)`. PWAs at the HAL layer report the parent
   browser's PID, never the PWA bundle.
2. Walks `activeInputProcesses()`, collects the PIDs whose bundle matches the
   parent, and installs a `kAudioProcessPropertyIsRunningInput` listener on
   each per-process AudioObject (off-main, via a dedicated dispatch queue
   `com.muesli.native.browser-mic`).
3. Also installs a global listener on
   `(kAudioHardwarePropertyProcessObjectList, kAudioObjectSystemObject)` so
   that a process restart or a newly-spawned helper process is observed and
   reattached without polling.
4. When *any* listener fires, hops to the MainActor, re-reads
   `activeInputProcesses()`, and if the parent bundle no longer holds an
   input device, schedules an 8-second debounce (`graceSeconds`). After the
   debounce fires it re-reads `activeInputProcesses()` one final time. Only
   if the bundle is still absent does the monitor invoke its
   `onCallEnded(bundleID:)` callback. The coordinator's `handleAutoStop`
   then transitions to `.idle` with `.autoStopped` and invokes the injected
   `recordingStopper`.

The debounce absorbs the ≤ 2 s gap during AirPods/USB-device migration and the
brief release/reacquire that some sites do when toggling mute. 8 seconds was
chosen empirically as the next-power-of-two above 5 s (the largest mic-switch
gap we measured) and is configurable via the monitor's init for tests.

## PWA roll-up

At the HAL layer, PWAs report their *parent* browser's bundle (Chrome PWAs →
`com.google.Chrome`, Safari Web Apps → `com.apple.Safari`, etc.). The monitor
maps PWA bundle IDs back to the parent before installing listeners so callers
can hand it the user-facing bundle (the PWA's) and not worry about HAL-layer
plumbing. `browserBundlesEligibleForAutoStop` enumerates the browser family
bundles v2.1 will auto-stop for.

## Consequences

- **No new dependencies, no new TCC permissions.** All APIs are already
  reachable from the existing v0/v1 codepath.
- **Bundle-ID precision, not URL precision.** When the user has *two* tabs in
  the same browser both using `getUserMedia`, the browser PID keeps the mic;
  auto-stop won't fire until *both* tabs release. Per-tab attribution is not
  exposed without an extension.
- **Warm streams defer auto-stop.** Apps that keep a `MediaStreamTrack` alive
  across UI states (Slack huddle minimised, Meet pre-join minimised, Discord
  push-to-talk armed) won't release the mic until the user closes the tab.
  Documented in the Settings toggle label ("experimental") and the first-run
  modal.
- **Mic switch mid-meeting is invisible.** The 8 s debounce absorbs AirPods /
  USB-mic hand-offs.
- **PWA hand-off doesn't double-trigger.** When a browser "Open in app" flow
  hands the call to a native client, the browser releases the mic and the
  native bundle picks it up. The coordinator's `handleAutoStop` is guarded by
  a `state.bundleID == observed bundleID` check, and `transition(to: .idle)`
  is preceded by `monitor.stopWatching()`. The v0 detector then handles the
  native side via its existing `isRecordingNowProbe` path. No stop-then-restart
  pingpong.

## Known limitations

- **Concurrent-mic tabs in the same browser.** Auto-stop waits for *all* tabs
  to release. Per ADR 0003 we don't have per-tab attribution without an
  extension.
- **Warm streams (Slack huddle minimised, Meet pre-join minimised).** The
  browser PID still holds the input device; auto-stop defers.
- **Mic device migration.** AirPods / USB hand-off causes a brief release —
  the 8 s debounce hides it from the user.
- **PWA-to-native hand-off.** Native client takeover stops the browser
  watcher, but the v0 detector path then owns the native side. The `state`
  guard in `handleAutoStop` prevents double-stops.

## References

- Apple Developer documentation: `AudioObjectAddPropertyListenerBlock`,
  `kAudioHardwarePropertyTranslatePIDToProcessObject`,
  `kAudioProcessPropertyIsRunningInput`,
  `kAudioHardwarePropertyProcessObjectList`.
- v2.1 ticket: `tickets/ticket-v2.1.md`.
- v1 mic-ownership gate: ADR 0003.
