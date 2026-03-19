# Audit Hardening Fixes

This ExecPlan is a living document. The sections `Progress`,
`Surprises & Discoveries`, `Decision Log`, and
`Outcomes & Retrospective` must be kept up to date as work proceeds.

This repository does not contain a checked-in `PLANS.md`, so this document
follows the machine-local reference at `/Users/codex/Downloads/Code Files/PLANS.md`.

## Purpose / Big Picture

This change turns the verified audit findings into a small, reviewable hardening
patch. After this work, meeting transcripts should no longer lose completed mic
chunks during async chunk rotation, system-audio startup failures should not
leave the app in a false-success state, the dictation date filter query should
stop interpolating SQL directly, and the repo should stop claiming ChatGPT
tokens live in Keychain when the code writes them to disk. The result should be
visible through focused Swift tests and a clean PR that explains the fixes in
plain language.

## Progress

- [x] (2026-03-19 16:34 IST) Verified the audit findings again and downgraded
      the SQL item from “proven exploit” to “unsafe API sink in the store
      layer”.
- [x] (2026-03-19 16:35 IST) Created branch
      `audit/muesli-hardening-report-and-fixes`.
- [x] (2026-03-19 16:35 IST) Cleared the stale SwiftPM `.build/.lock` file left
      by the earlier dependency fetch.
- [x] (2026-03-19 16:43 IST) Added regression tests for SQL binding, config
      file permissions, and meeting chunk collection.
- [x] (2026-03-19 16:57 IST) Implemented the store, recorder, and
      meeting-session fixes.
- [x] (2026-03-19 17:01 IST) Updated README storage wording and wrote the audit
      report.
- [x] (2026-03-19 17:07 IST) Verified package compilation with
      `swift build --package-path native/MuesliNative` and verified the CLI
      still responds via `swift run --package-path native/MuesliNative
      muesli-cli spec`.
- [ ] (2026-03-19 17:07 IST) Targeted Swift tests are added but could not be
      executed in this environment because the active developer directory only
      exposes Command Line Tools, while the repo test target imports the Swift
      `Testing` module.
- [ ] Commit, push, and open a PR with a human-written report.

## Surprises & Discoveries

- Observation: the earlier `swift test --package-path native/MuesliNative`
  attempt spent most of its time fetching large transitive dependencies from
  FluidAudio and related Swift packages, and it left a stale lock file behind.
  Evidence: `native/MuesliNative/.build/.lock` existed with PID `88677`, but
  `ps -p 88677` returned no live process.

- Observation: the secret-storage issue is partly documentation drift, not just
  code behavior. The code already sets `0600` on `chatgpt-auth.json`, while
  `config.json` gets no explicit permission hardening.
  Evidence: `ChatGPTAuthManager.saveTokens()` sets POSIX permissions, while
  `ConfigStore.save()` only writes atomically.

- Observation: package tests do not run cleanly on this machine even before the
  new assertions execute, because the active developer directory is
  `/Library/Developer/CommandLineTools` and the repository test target imports
  the Swift `Testing` module.
  Evidence: `swift test --package-path native/MuesliNative --filter
  MeetingChunkCollectorTests` fails in existing test files with `no such module
  'Testing'`, and `xcodebuild -version` reports that full Xcode is not active.

## Decision Log

- Decision: keep the SQL finding in scope and fix it even though the current UI
  only passes internally generated ISO8601 values.
  Rationale: the store API is still unsafe by construction and cheap to repair.
  Date/Author: 2026-03-19 / Codex

- Decision: fix the token-storage finding by aligning docs and hardening config
  file permissions, not by redesigning the whole secret-storage system in one
  pass.
  Rationale: moving every secret into Keychain would be a larger product change;
  this pass is aimed at verified bugs and low-risk hardening that can be
  reviewed and merged quickly.
  Date/Author: 2026-03-19 / Codex

- Decision: replace background chunk side effects in `MeetingSession` with
  tracked task results that are awaited before transcript merge.
  Rationale: this removes the race without needing a broad architecture change.
  Date/Author: 2026-03-19 / Codex

## Outcomes & Retrospective

The patch now covers every fix that was in scope for this pass. The code builds
cleanly, the CLI still runs, the SQL sink is parameterized, config writes are
permission-hardened, meeting chunk tasks are collected before transcript merge,
and the README no longer claims Keychain storage for ChatGPT tokens. The only
gap left before shipping is repository-hosting work: commit, push, and PR
creation. The local test environment still lacks the full setup needed to run
the repo’s `Testing`-based suite.

## Context and Orientation

The Swift package lives in `native/MuesliNative`. The storage layer is in
`native/MuesliNative/Sources/MuesliCore/DictationStore.swift`. The desktop app
logic is in `native/MuesliNative/Sources/MuesliNativeApp`. Three files matter
most for the fixes:

- `MeetingSession.swift` manages live meeting recording and async chunk
  transcription.
- `SystemAudioRecorder.swift` wraps `ScreenCaptureKit` and writes a temporary
  WAV file for remote speaker audio.
- `ConfigStore.swift` persists `AppConfig`, which includes provider API keys.

The most relevant tests already live in
`native/MuesliNative/Tests/MuesliTests`. `DictationStoreTests.swift` covers the
SQLite store. `ConfigStoreTests.swift` covers config persistence. There are no
existing tests for `MeetingSession` or `SystemAudioRecorder`, so the fix there
should either add a narrowly testable helper or keep the change small and
verified through targeted logic tests.

## Plan of Work

Start with tests. In `DictationStoreTests.swift`, add a regression test that
passes a malicious-looking `fromDate` string and proves the query treats it as a
value, not SQL. In `ConfigStoreTests.swift`, add a test that saves config and
asserts the resulting file mode is owner-only. Run those tests first and watch
them fail.

Then update `DictationStore.recentDictations()` so it builds the optional date
filters with `?` placeholders and binds the values in order before binding
`LIMIT` and `OFFSET`.

For config hardening, update `ConfigStore.save()` to set `0600` on the file
after writing, mirroring what `ChatGPTAuthManager` already does for the OAuth
token file.

For the meeting transcript race, replace the shared mutable
`accumulatedMicSegments` append path with tracked `Task<SpeechSegment?, Never>`
instances. `rotateChunk()` should store the created task instead of mutating the
array from inside the task. `stop()` should await all pending tasks, collect
their returned segments, sort them by timestamp, and only then merge the final
transcript.

For the system-audio startup issue, keep the public API small. `start()` should
leave the recorder in a clean state if async stream startup fails, and `stop()`
should finalize or clean up based on the actual file state instead of only
`isRecording`.

Finally, update `README.md` so the token-storage sentence matches reality, and
add an audit report document describing the verified issues, scope, fixes, and
remaining risk.

## Concrete Steps

From `/Users/codex/muesli`:

1. Run focused failing tests:

    swift test --package-path native/MuesliNative --filter DictationStoreTests
    swift test --package-path native/MuesliNative --filter ConfigStoreTests

2. Implement the smallest code changes needed to satisfy those tests.

3. Run the same focused tests again and expect them to pass.

4. Add and run any new focused tests for helper logic introduced by the
   meeting-session fix.

5. Run the broader package test command when dependency resolution is stable:

    swift test --package-path native/MuesliNative

6. Review the final diff, commit, push, and open a PR with the audit report and
   fix summary.

## Validation and Acceptance

Acceptance is:

- the dictation date filter test proves a malicious string does not alter query
  behavior;
- the config save test proves `config.json` is written with owner-only
  permissions;
- the meeting-session logic no longer merges transcripts before pending chunk
  tasks finish;
- the system-audio recorder no longer strands temp files or false-success state
  after async startup failure;
- the README no longer says tokens are stored in Keychain if they are not.

If the full package tests complete in this environment, they should stay green.
If dependency resolution makes the full suite impractical, the PR must say that
clearly and include the focused passing commands that were run.

Validated in this environment:

- `swift build --package-path native/MuesliNative`
- `swift run --package-path native/MuesliNative muesli-cli spec`

## Idempotence and Recovery

The code changes are additive and safe to re-run. The focused tests can be run
multiple times without mutating external state beyond files under the app’s test
temporary directories. If a SwiftPM lock becomes stale again, remove only
`native/MuesliNative/.build/.lock` after confirming the PID inside it is no
longer running.

## Artifacts and Notes

Important source anchors for the audit:

    native/MuesliNative/Sources/MuesliCore/DictationStore.swift
    native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift
    native/MuesliNative/Sources/MuesliNativeApp/SystemAudioRecorder.swift
    native/MuesliNative/Sources/MuesliNativeApp/ConfigStore.swift
    native/MuesliNative/Sources/MuesliNativeApp/ChatGPTAuthManager.swift
    README.md

## Interfaces and Dependencies

Do not add new third-party dependencies. Keep all changes inside the existing
Swift package. Any new helper introduced for meeting chunk collection should use
plain Swift concurrency and stay in `native/MuesliNative/Sources/MuesliNativeApp`
unless it is pure storage logic that belongs in `MuesliCore`.

Revision note: created this ExecPlan before code edits so the audit fixes can
be implemented and verified in a disciplined sequence.

Revision note: updated after implementation to record the added tests, the
completed code and documentation changes, and the environment-specific test
limitation around the Swift `Testing` module.
