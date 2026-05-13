# Auto-Capture Progress

Phase-by-phase rollout of the opt-in Auto-Capture subsystem. Each phase lands
behind a feature flag; the master toggle defaults to off until users opt in.

| Phase | Scope | Status | Notes |
|---|---|---|---|
| v0 | Native + already-detected-browser auto-start; settings pane; CLI status subcommand; tests | In progress | First working build on `feat/auto-capture-v0`; awaiting human review and a real Teams/Zoom run-through |
| v1 | AppleScript browser URL polling; per-browser opt-in; macOS Automation permission step in onboarding; persistent denial banner | In progress | First working build on `feat/auto-capture-v1`; 29 new tests in `BrowserURLPollerTests` plus `BrowserMeetingURLMatcher` patterns. Manual Teams-in-Chrome / Meet-in-Safari run-through pending. |
| v2 | PWA discovery | Not started | |
| v3 | MV3 extension + native messaging host | Not started | |
| v4 | Safari Web Extension | Not started | |
