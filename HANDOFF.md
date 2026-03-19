# Handoff

## Current task

Audit the cloned `muesli` repository from
`https://github.com/pHequals7/muesli` and find concrete issues.

## Recent user prompts

- `https://github.com/pHequals7/muesli - we have to audit this code - can you download this and lets find issues in this?`
- `Did you download the code up for us?`
- `Verify these issues strictly and let me know if it works.`

## Current status

- Repo cloned to `/Users/codex/muesli`.
- Focused audit completed on the main trust boundaries:
  - CLI surface
  - SQLite storage layer
  - ChatGPT OAuth flow
  - secret storage
  - meeting recording/transcription pipeline
- Fixes are now implemented on branch
  `audit/muesli-hardening-report-and-fixes`.
- Added a living ExecPlan at
  `docs/plans/2026-03-19-audit-hardening-execplan.md`.
- Added an audit report at
  `docs/reports/2026-03-19-audit-hardening-report.md`.

## Verified findings and fix status

1. `native/MuesliNative/Sources/MuesliCore/DictationStore.swift`
   builds SQL for `fromDate` / `toDate` filters with string interpolation
   instead of binding parameters. This is strictly true at the store layer, but
   current app code only feeds ISO8601 values from internal date pickers, so it
   is a latent injection sink rather than a proven current UI exploit.
   Status: fixed with bound parameters.
2. `native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift`
   appends chunk transcripts from multiple async tasks into
   `accumulatedMicSegments` without synchronization and does not wait for all
   chunk tasks before merging the final transcript.
   Status: fixed by replacing shared mutable async writes with tracked tasks
   that are drained and sorted before merge.
3. `native/MuesliNative/Sources/MuesliNativeApp/SystemAudioRecorder.swift`
   reports success before `SCStream` startup actually succeeds. If async stream
   startup fails, the recorder flips `isRecording` to false later, which makes
   `stop()` skip finalization and cleanup.
   Status: fixed by waiting for startup completion in `start()` and cleaning up
   explicitly on failure.
4. `README.md` says ChatGPT OAuth tokens are stored in Keychain, but
   `native/MuesliNative/Sources/MuesliNativeApp/ChatGPTAuthManager.swift`
   migrates them into `chatgpt-auth.json`. `ConfigStore.swift` also persists
   OpenAI/OpenRouter API keys in `config.json`.
   Status: README corrected; `config.json` now gets `0600` permissions on save.

## Verification notes

- `swift build --package-path native/MuesliNative` passes.
- `swift run --package-path native/MuesliNative muesli-cli spec` passes.
- `swift test --package-path native/MuesliNative --filter ...` still does not
  run cleanly in this environment because the active developer directory is
  Command Line Tools, not full Xcode, and the repo’s tests import the Swift
  `Testing` module.

## Remaining work

- Review final diff.
- Commit the branch.
- Push the branch and open a PR with the audit report summary.

## Suggested next steps

- Finish or rerun the Swift test suite once dependency resolution completes.
- Decide whether to convert this from an audit-only report into a patch set.
- If fixing:
  - parameterize the dictation date filters,
  - serialize or await meeting chunk transcription tasks,
  - make `SystemAudioRecorder.start()` fail fast on stream startup failure,
  - move secrets back to Keychain or clearly document file-based storage.
