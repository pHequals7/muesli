# Muesli OpenHands Instructions

You are working on Muesli, a Swift/SwiftUI macOS app.

## Primary Goal

- Fix current PR review findings from Claude Code and Greptile.
- P0/P1 findings are blocking if they still apply to the current HEAD.
- P2 findings are optional unless they are low-risk and clearly correct.
- Greptile findings may be stale. Verify each finding against current code before changing anything.
- If the trigger asks specifically for P0/P1 fixes and there are no current code-backed P0/P1 findings, do not fix P2/minor items unless the trigger explicitly asks for them.

## Hard Rules

- Do not use or install compromised LiteLLM versions `1.82.7` or `1.82.8`.
- Never run `./scripts/dev-test.sh --clean`.
- Never delete, reset, replace, or migrate away local MuesliDev data.
- Never run release scripts.
- Never claim real local macOS UX verification from CI or a cloud environment.
- Do not claim verification of permission prompts, system audio capture, floating window behavior, Sparkle update behavior, or latency-sensitive typing unless it was explicitly tested on a local Mac.
- Final app acceptance requires local MuesliDev QA by the maintainer.

## Verification

- Prefer targeted Swift tests first when a fix is localized.
- Run `swift test --package-path native/MuesliNative` when possible.
- If the environment cannot build macOS-specific code or fetch dependencies, say so plainly and rely on CI/local QA for that layer.
- Do not treat a skipped or unavailable local build as proof that the app works.

## PR Review Policy

- Read the latest Claude Code and Greptile comments before editing.
- Classify each review item as current blocking, stale, optional, or out-of-scope.
- For stale findings, cite the current file/function evidence that makes the finding obsolete.
- Fix all current code-backed P0/P1 findings.
- Do not spend time on P2/minor findings when the request is scoped to P0/P1 only.
- Keep changes narrow and consistent with existing SwiftUI/AppKit patterns.
- Commit fixes directly to the PR branch.
- Stop when there are no current code-backed P0/P1 findings and summarize what remains for local MuesliDev QA.
