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
