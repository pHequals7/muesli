# Auto-Capture Progress

Phase-by-phase rollout of the opt-in Auto-Capture subsystem. Each phase lands
behind a feature flag; the master toggle defaults to off until users opt in.

| Phase | Scope | Status | Notes |
|---|---|---|---|
| v0 | Native + already-detected-browser auto-start; settings pane; CLI status subcommand; tests | In progress | First working build on `feat/auto-capture-v0`; awaiting human review and a real Teams/Zoom run-through |
| v1 | AppleScript browser URL polling; per-browser opt-in; macOS Automation permission step in onboarding; persistent denial banner | In progress | First working build on `feat/auto-capture-v1`; 29 new tests in `BrowserURLPollerTests` plus `BrowserMeetingURLMatcher` patterns. Manual Teams-in-Chrome / Meet-in-Safari run-through pending. |
| v2 | PWA discovery | In progress | First working build on `feat/auto-capture-v2`; 19 new tests in `PWADiscoveryTests`. Manual Teams-as-Chrome-PWA / Safari-Web-App run-through pending. |
| v2.1 | Browser/PWA auto-stop (CoreAudio HAL mic-release listener) + remove broken v1 Automation onboarding step | In progress | First working build on `fix/auto-capture-v2.1-stop-detection`; new `BrowserMicReleaseMonitor` + tests, `auto_stop_enabled` config key (default true), single experimental Settings toggle, first-run modal disclosure sentence, `OnboardingProgress` schema bumped 5 → 6. See ADR 0009. Live Teams-Web / Safari-Web-App run-through pending. |
| v3 | MV3 extension + native messaging host | Not started | |
| v4 | Safari Web Extension | Not started | |
