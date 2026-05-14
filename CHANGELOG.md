# Changelog

All notable changes to this fork are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Auto-Capture v0: opt-in master toggle that starts meeting recording when the
  existing `MeetingDetector` reports a high-tier detection. Adds a Settings
  pane with per-app toggles, a start-delay slider, a strict "require calendar
  match" toggle, and a Focus / Do-Not-Disturb pause. First-run prompts are
  shown once per detected bundle ID, auto-decline after 30 seconds, and store
  acknowledgements in `auto_capture.acknowledged_app_bundle_ids`. A new
  `muesli-cli auto-capture status` subcommand surfaces the current
  configuration for headless diagnostics. The calendar-driven
  `auto_record_meetings` path is unchanged.
- Auto-Capture v1: opt-in AppleScript URL polling for browsers that the
  existing detection path doesn't already cover. Per-browser flags for Chrome,
  Edge, Brave, Arc, and Safari live under
  `auto_capture.browser_url_polling.*`; all default to off. While at least one
  flag is enabled, a 1Hz watchdog asks `AudioProcessAttributionCollector` if
  one of those browsers is using a microphone — and only then does the poller
  invoke `NSAppleScript` at 0.5s cadence to read the active tab URL. URLs are
  matched against `meet.google.com`, `*.zoom.us/wc/*`, `teams.microsoft.com`,
  `teams.live.com`, `teams.cloud.microsoft`, and `app.webex.com`. Matches flow
  through the existing v0 `AutoCaptureCoordinator` state machine. macOS
  Automation permission is probed via `AEDeterminePermissionToAutomateTarget`
  without prompting; denied targets are surfaced via a persistent banner in
  the Auto-Capture settings pane and a new "Browser Auto-Capture" step in
  onboarding (schema v5). See `docs/decisions/0003-applescript-vs-extension-browser-detection.md`.
- Auto-Capture v2: PWA discovery. A new `PWADiscovery` module scans
  `~/Applications/Chrome Apps.localized/` for Chrome PWAs (bundle IDs of the
  form `com.google.Chrome.app.<id>`) and `/Applications/` plus
  `~/Applications/` for Safari Web Apps (`com.apple.Safari.WebApp.*` bundle
  IDs). Discovered PWAs are surfaced in the Auto-Capture settings pane as a
  new "PWAs" section with per-entry toggles and a Refresh button; toggling an
  entry on adds its bundle ID to `auto_capture.allowed_app_bundle_ids` so the
  existing coordinator allowlist path picks it up — no new tier in the state
  machine. The scan also best-effort recovers each Chrome PWA's `start_url`
  from `~/Library/Application Support/Google/Chrome/<profile>/Web
  Applications/`. Results are cached in `auto_capture.pwa.cached_entries`,
  refreshed off the main actor on app launch and on user-driven Refresh.
  Filesystem work only — no AppleScript, no spawned processes.
- Auto-Capture v2.1: experimental auto-stop for browser-hosted and PWA-hosted
  meetings. New `BrowserMicReleaseMonitor` installs CoreAudio HAL listeners
  (`kAudioProcessPropertyIsRunningInput`) on every per-process AudioObject
  owned by the watched browser-family bundle, plus a global
  `kAudioHardwarePropertyProcessObjectList` listener for reattach. PWAs roll
  up to the parent browser bundle before listener install. When the bundle
  releases the mic for ≥ 8 seconds, the monitor fires `onCallEnded`;
  `AutoCaptureCoordinator.handleAutoStop` checks `auto_capture.auto_stop_enabled`
  (default `true`, snake-case JSON key, decodes-without-key for back-compat),
  invokes the new `recordingStopper` closure (`MuesliController.stopMeetingRecording()`),
  and transitions to `.idle` with `AutoCaptureDecisionReason.autoStopped`.
  Settings adds one toggle: "Auto-stop when call ends (experimental)" in the
  Behaviour section. The first-run modal appends one sentence disclosing the
  feature as experimental. Native meeting-app auto-stop is unchanged — v0's
  existing `isRecordingNowProbe` path still handles Zoom/Teams desktop. See
  `docs/decisions/0009-coreaudio-hal-mic-release-stop-detection.md`.

### Removed

- Auto-Capture v1 Browser Auto-Capture onboarding step. Its 1 Hz
  `AutomationPermissionProbe.status` poll raced the synchronous interactive
  `requestPermission` call, making the per-browser Request pill flip Request
  → Denied → Request. Users who later enable browser URL polling in Settings
  still get a persistent Automation-denied banner there.
  `OnboardingProgress.currentSchemaVersion` bumped from 5 to 6; saved progress
  at the removed step is reset to a fresh start.
