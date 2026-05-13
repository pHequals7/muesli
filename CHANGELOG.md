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
