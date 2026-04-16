# Context Handover — Migrate system audio capture from ScreenCaptureKit to CoreAudio tap

**Session Date:** 2026-04-16
**Repository:** muesli
**Branch:** main (pending — implement after PR #48 merges)

---

## Session Objective

Replace `SystemAudioRecorder` (ScreenCaptureKit `SCStream`) with a CoreAudio tap + aggregate device approach for system audio capture during meetings. This unblocks screenshot-based OCR for meeting visual context and downgrades the permission requirement from "Screen & System Audio Recording" to "System Audio" only.

## Why

1. **`CGWindowListCreateImage` conflicts with `SCStream`** — Discovered in PR #48: periodic screenshots during meetings cause `RPDaemonProxy: connection INTERRUPTED`, killing the system audio stream. The meeting gets stuck at "finalizing" indefinitely.
2. **Friendlier permission prompt** — "System Audio" vs "Screen & System Audio Recording" is less scary for users and would improve onboarding conversion.
3. **Better AEC alignment** — CoreAudio aggregate device delivers mic + system audio in the same hardware-synchronized callback, eliminating the timestamp alignment we currently do between AVAudioEngine (mic) and SCStream (system).

## Evidence from Granola

Granola's `granola.node` native addon implements both paths:

- **`ScreenCaptureKitListener`** — `SCStream` + `SCStreamDelegate` (same as Muesli)
- **`SystemAudioListener`** — CoreAudio tap + aggregate device (`setupTap`, `setupAggregateDevice`, `checkTapFormatChanged`)
- Controlled by `useCoreAudio` boolean flag, defaults to CoreAudio on macOS 14.2+
- Key symbols: `GRANOLA_AGGREGATE_DEVICE_NAME`, `GRANOLA_AUDIO_TAP_DEVICE_NAME`, `added-taps-to-aggregate-device`, `aggregate-device-created`

Binary at: `/Applications/Granola.app/Contents/Resources/native/granola.node`
Extracted source at: `/tmp/granola-extracted/dist-electron/audio_process/index.js`

## Implementation Approach

### New: `CoreAudioSystemRecorder.swift`

Replaces `SystemAudioRecorder.swift` (ScreenCaptureKit-based).

Steps:
1. **Create audio tap** on the default output device — captures all system audio output
2. **Create aggregate device** combining mic input + tap as second input
3. **Set up AUHAL AudioUnit** on the aggregate device with input callback
4. **Deliver buffers** via the same interface `MeetingSession` expects (PCM samples + timestamps)
5. **Handle format changes** — device switches (AirPods connect, HDMI plugged in) trigger tap format renegotiation
6. **Teardown** — destroy aggregate device + tap on stop. Register cleanup in `applicationWillTerminate` and a `SIGTERM` handler to prevent leaked phantom devices.

### Modify: `MeetingSession.swift`

Swap `SystemAudioRecorder` for `CoreAudioSystemRecorder`. The buffer delivery interface stays the same — only the capture backend changes.

### Modify: `MeetingNeuralAec.swift`

Simplify echo cancellation — mic and system audio arrive hardware-synchronized in the same callback. Remove timestamp alignment code.

### Modify: `OnboardingView.swift`

Update permissions step — request "System Audio" instead of "Screen Recording" for system audio capture. Screen Recording still needed for meeting OCR screenshots, but can be deferred/optional.

### Re-enable: Screenshot OCR for meetings

Once `SCStream` is removed, `CGWindowListCreateImage` no longer conflicts. Re-add `ScreenContextCapture.captureOnce()` (OCR) to `MeetingScreenContextCollector` instead of the AX-based fallback.

## Key Risks

- **Aggregate device cleanup on crash** — Leaked devices appear as phantom audio devices in System Settings. Must handle `SIGTERM`, `applicationWillTerminate`, and ideally check for stale devices on launch.
- **Format renegotiation** — User switches from speakers to AirPods mid-meeting. Tap format changes, AudioUnit needs reconfiguration. Granola handles this (`checkTapFormatChanged`). Must test extensively.
- **Per-app isolation** — `AudioHardwareCreateProcessTap` (macOS 14.4+) can tap specific processes. Not needed for MVP (capture all system audio), but worth noting for future.
- **Fallback** — Keep `SystemAudioRecorder` as a fallback for edge cases where CoreAudio tap fails (rare hardware, virtual audio drivers). Feature flag to switch between paths.

## Testing Plan

1. Built-in speakers — basic meeting recording
2. AirPods/Bluetooth — connect before and during meeting
3. External DAC/USB audio
4. HDMI audio output
5. Device hot-swap mid-meeting (plug in headphones while recording)
6. Force-quit during recording — verify no phantom aggregate device left behind
7. Relaunch after crash — verify stale device detection and cleanup

## Estimate

300-500 lines of CoreAudio Swift code. 1-2 days implementation + 1 day device testing. Separate PR from screen context work.

## Files to Create/Modify

- **New**: `CoreAudioSystemRecorder.swift`
- **Modify**: `MeetingSession.swift` (swap recorder)
- **Modify**: `MeetingNeuralAec.swift` (simplified AEC with synchronized buffers)
- **Modify**: `OnboardingView.swift` (permission prompt)
- **Modify**: `ScreenContextCapture.swift` (re-enable OCR for meetings)
- **Keep**: `SystemAudioRecorder.swift` (fallback, feature-flagged)
