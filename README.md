<p align="center">
  <img src="assets/muesli_app_icon.png" alt="Muesli" width="128" height="128" />
</p>

<h1 align="center">Muesli</h1>

<p align="center">
  <strong>Local-first dictation & meeting transcription for macOS</strong><br>
  100% on-device speech-to-text · Zero cloud costs · Privacy by default
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  <a href="https://buymeacoffee.com/phequals7"><img src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=white" alt="Buy Me A Coffee" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey?logo=apple" alt="macOS 14.2+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-optimized-green" alt="Apple Silicon" />
</p>

---

## What is Muesli?

Muesli is a **32MB native macOS app** that combines **WisprFlow-style dictation** and **Granola-style meeting transcription** in one lightweight tool. All transcription runs locally on Apple Silicon — your audio never leaves your device unless you want to (meeting summaries).

### Dictation
Hold your hotkey (or double-tap for hands-free mode) → speak → release → transcribed text is pasted at your cursor. **~0.13 second latency** via Parakeet TDT on the Apple Neural Engine.

### Meeting Transcription
Start a meeting recording → Muesli captures your mic (You) and system audio (Others) simultaneously → VAD-driven chunked transcription happens during the meeting at natural speech boundaries → speaker diarization identifies individual remote speakers (Speaker 1, Speaker 2, etc.) → when you stop, the transcript is ready in seconds, not minutes. Generate structured meeting notes via OpenAI, free OpenRouter models, or your ChatGPT Plus/Pro subscription.

---

## Features

- **Native Swift, zero Python** — Pure Swift app with CoreML and Metal backends. No bundled runtimes, no subprocess IPC. 32MB total.
- **Multiple ASR models** — Choose from Parakeet TDT (Neural Engine), Whisper Small/Medium/Large Turbo (Metal via whisper.cpp), and Qwen3 ASR (52 languages, CoreML). NVIDIA Nemotron streaming coming soon.
- **Hold-to-talk & hands-free** — Hold hotkey for quick dictation, or double-tap for sustained recording.
- **Meeting recording** — Captures mic + system audio (including Bluetooth/AirPods) via ScreenCaptureKit.
- **VAD-driven chunk rotation** — Silero VAD detects natural speech boundaries in real-time, splitting mic audio at pauses instead of fixed intervals. No mid-sentence cuts.
- **Speaker diarization** — Identifies individual speakers in system audio (Speaker 1, Speaker 2, etc.) using FluidAudio's pyannote-based CoreML diarization model.
- **Camera-based meeting detection** — Instantly detects when your webcam turns on (CoreMediaIO event listener). Camera active = meeting detected, no matter which app.
- **Filler word removal** — Automatically strips "uh", "um", "er", "hmm" and verbal disfluencies.
- **AI meeting notes** — BYOK with OpenAI or OpenRouter, or sign in with your ChatGPT Plus/Pro subscription (no API key needed). Auto-generated meeting titles. Re-summarize any meeting.
- **ChatGPT OAuth** — Sign in with your existing ChatGPT subscription via browser-based OAuth (PKCE). Tokens stored in the app support directory with owner-only file permissions.
- **Personal dictionary** — Add custom words and replacement pairs. Jaro-Winkler fuzzy matching auto-corrects transcription output.
- **Model management** — Download, delete, and switch between models from the Models tab. Background downloads that don't block the app.
- **Meeting auto-detection** — Detects when Zoom, Chrome, Teams, FaceTime, or Slack activates the mic or camera. Shows a notification to start recording.
- **Configurable hotkeys** — Choose any modifier key (Cmd, Option, Ctrl, Fn, Shift) for dictation.
- **Onboarding** — First-launch wizard with model selection, permissions setup, hotkey configuration, and optional API key entry.
- **Dark & light mode** — Adaptive theme with toggle in Settings.
- **SwiftUI dashboard** — Dictation history, meeting notes (Notes-style split view), dictionary, models, shortcuts, settings, about page.
- **Floating indicator** — Draggable pill showing recording state, waveform animation, click-to-stop for meetings.

---

## Install

### Download (recommended)

Download the latest `.dmg` from [Releases](https://github.com/pHequals7/muesli/releases), open it, and drag Muesli to your Applications folder.

### Homebrew

```bash
brew tap pHequals7/muesli
brew install --cask muesli
```

### Build from source

**Requirements:** macOS 14.2+, Xcode 16+

```bash
# Clone
git clone https://github.com/pHequals7/muesli.git
cd muesli

# Build and install to /Applications
./scripts/build_native_app.sh
```

The transcription model (~450MB for Parakeet v3) downloads automatically on first use.

---

## Agent CLI

Muesli bundles an agent-friendly local CLI inside the app bundle:

- Installed path: `/Applications/Muesli.app/Contents/MacOS/muesli-cli`
- Dev path: `native/MuesliNative/.build/arm64-apple-macosx/debug/muesli-cli`

The CLI is designed for coding agents such as Codex and Claude Code. It exposes meetings, dictations, raw transcripts, and stored notes as stable JSON so an agent can analyze them with its own model and write notes back without requiring a user-supplied OpenAI or OpenRouter key.

### What agents should do

1. Discover the CLI:
   ```bash
   command -v muesli-cli || echo "/Applications/Muesli.app/Contents/MacOS/muesli-cli"
   ```
2. Inspect the command contract:
   ```bash
   /Applications/Muesli.app/Contents/MacOS/muesli-cli spec
   ```
3. List recent meetings or dictations:
   ```bash
   /Applications/Muesli.app/Contents/MacOS/muesli-cli meetings list --limit 10
   /Applications/Muesli.app/Contents/MacOS/muesli-cli dictations list --limit 10
   ```
4. Fetch a full record:
   ```bash
   /Applications/Muesli.app/Contents/MacOS/muesli-cli meetings get 125
   /Applications/Muesli.app/Contents/MacOS/muesli-cli dictations get 42
   ```
5. Summarize or analyze locally in the agent.
6. Write improved meeting notes back:
   ```bash
   cat notes.md | /Applications/Muesli.app/Contents/MacOS/muesli-cli meetings update-notes 125 --stdin
   ```

### Commands

- `muesli-cli spec`
- `muesli-cli info`
- `muesli-cli meetings list [--limit N] [--folder-id ID]`
- `muesli-cli meetings get <id>`
- `muesli-cli meetings update-notes <id> (--stdin | --file <path>)`
- `muesli-cli dictations list [--limit N]`
- `muesli-cli dictations get <id>`

### JSON contract

All CLI commands return JSON on stdout.

Success shape:

```json
{
  "ok": true,
  "command": "muesli-cli meetings get",
  "data": {},
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-03-17T00:00:00Z",
    "dbPath": "/Users/example/Library/Application Support/Muesli/muesli.db",
    "warnings": []
  }
}
```

Failure shape:

```json
{
  "ok": false,
  "command": "muesli-cli meetings get 999",
  "error": {
    "code": "not_found",
    "message": "No meeting exists with id 999.",
    "fix": "Run `muesli-cli meetings list` to find a valid ID."
  },
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-03-17T00:00:00Z",
    "dbPath": "",
    "warnings": []
  }
}
```

Important meeting fields:

- `rawTranscript`
- `formattedNotes`
- `notesState`
- `calendarEventID`
- `micAudioPath`
- `systemAudioPath`

`notesState` values:

- `missing`
- `raw_transcript_fallback`
- `structured_notes`

### Notes for agent authors

- The CLI is JSON-first and intended to be machine-consumed.
- `formattedNotes` is the only write-back surface in v1.
- `rawTranscript` is read-only and should be treated as source material.
- If `notesState` is `missing` or `raw_transcript_fallback`, agents should prefer summarizing from `rawTranscript`.
- Use `--db-path` or `--support-dir` only when the default Muesli data location is wrong.

---

## Models

| Model | Backend | Runtime | Size | Languages | Latency |
|-------|---------|---------|------|-----------|---------|
| **Parakeet v3** (recommended) | FluidAudio | CoreML / Neural Engine | ~450 MB | 25 languages | ~0.13s |
| Parakeet v2 | FluidAudio | CoreML / Neural Engine | ~450 MB | English only | ~0.13s |
| Qwen3 ASR | FluidAudio | CoreML / Neural Engine | ~1.3 GB | 52 languages | ~2-3s |
| Whisper Small | whisper.cpp | Metal / CPU | ~190 MB | English only | ~1-2s |
| Whisper Medium | whisper.cpp | Metal / CPU | ~1.5 GB | English only | ~2-3s |
| Whisper Large Turbo | whisper.cpp | Metal / CPU | ~600 MB | Multilingual | ~2-4s |

Models download on demand from HuggingFace. Manage them from the **Models** tab in the dashboard.

---

## Permissions

Muesli needs these macOS permissions (guided during onboarding):

| Permission | Why |
|---|---|
| **Microphone** | Record audio for dictation and meetings |
| **System Audio Recording** | Capture call audio from Zoom/Meet/Teams |
| **Accessibility** | Simulate Cmd+V to paste transcribed text |
| **Input Monitoring** | Detect hotkey presses globally |
| **Calendar** *(optional)* | Auto-detect upcoming meetings |

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Native Swift / SwiftUI App (38MB)                   │
│  ├── FluidAudio (Parakeet TDT + Qwen3 ASR on ANE)   │
│  ├── SwiftWhisper (whisper.cpp on Metal/CPU)          │
│  ├── Silero VAD (streaming voice activity detection)  │
│  ├── Speaker Diarization (pyannote CoreML on ANE)     │
│  ├── ChatGPTAuthManager (OAuth PKCE + WHAM API)       │
│  ├── CameraActivityMonitor (CoreMediaIO listeners)    │
│  ├── StreamingMicRecorder (AVAudioEngine real-time)    │
│  ├── FillerWordFilter (uh/um removal)                 │
│  ├── CustomWordMatcher (Jaro-Winkler fuzzy)           │
│  ├── HotkeyMonitor (configurable modifier keys)       │
│  ├── SystemAudioRecorder (ScreenCaptureKit)           │
│  ├── MeetingSession (VAD-driven chunked transcription)│
│  ├── MeetingSummaryClient (OpenAI / OpenRouter / ChatGPT) │
│  ├── FloatingIndicatorController (UI pill)            │
│  └── SwiftUI Dashboard (dictations, meetings,         │
│       dictionary, models, shortcuts, settings)        │
└──────────────────────────────────────────────────────┘
```

Everything runs in-process. No subprocesses, no IPC, no Python runtime.

---

## Tech Stack

| Component | Technology |
|---|---|
| App | Swift, AppKit, SwiftUI |
| Primary ASR | [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT + Qwen3 ASR on CoreML/ANE) |
| Whisper ASR | [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (whisper.cpp on Metal) |
| Voice activity | Silero VAD via FluidAudio (streaming, event-driven) |
| Speaker diarization | pyannote via FluidAudio (CoreML on ANE) |
| Camera detection | CoreMediaIO property listeners (event-driven) |
| System audio | ScreenCaptureKit (`SCStream`) |
| Meeting notes | OpenAI / OpenRouter (BYOK) or ChatGPT subscription (OAuth) |
| Word correction | Jaro-Winkler similarity (native Swift) |
| Storage | SQLite (WAL mode) |
| Signing | Developer ID + hardened runtime (notarization ready) |

---

## Contributing

Contributions welcome! To get started:

```bash
git clone https://github.com/pHequals7/muesli.git
cd muesli
swift build --package-path native/MuesliNative -c release
swift test --package-path native/MuesliNative
./scripts/test_packaged_cli.sh
```

168 tests covering model configuration, custom word matching, filler removal, transcription routing, data persistence, CLI contract/path-resolution logic, speaker diarization alignment, token consolidation, camera-based meeting detection, and ChatGPT OAuth logic.

Current test scope:

- Covered by tests: CLI command contract generation, CLI path-resolution logic, SQLite read/write behavior, note-state classification, and meeting/dictation retrieval/update flows.
- Not covered by Swift unit tests: app-bundle packaging and copying `muesli-cli` into `/Applications/Muesli.app/Contents/MacOS`.
- Packaging is verified by `scripts/test_packaged_cli.sh`, which builds an isolated app bundle, checks that `Contents/MacOS/muesli-cli` exists and is executable, and runs `muesli-cli spec` from the packaged path.

Please open an issue before submitting large PRs.

---

## Support

If Muesli saves you time, consider supporting development:

<a href="https://buymeacoffee.com/phequals7"><img src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=for-the-badge&logo=buymeacoffee&logoColor=white" alt="Buy Me A Coffee" /></a>

---

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML speech models for Apple devices (Parakeet TDT, Qwen3 ASR, Silero VAD, speaker diarization)
- [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) — Swift wrapper for whisper.cpp
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — C/C++ Whisper inference
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) by Apple — system audio capture
- [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — FastConformer TDT speech recognition model
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) — Multilingual speech recognition (52 languages)
- [pyannote](https://github.com/pyannote/pyannote-audio) — Speaker diarization (via FluidAudio CoreML conversion)

---

## License

[MIT](LICENSE) — free and open source.
