# Muesli Cloud Agent Operating Guide

This file is tracked so cloud agents always receive core workflow rules, even when local handoff files are unavailable.

## Startup checklist

Run only lightweight setup commands first:

```bash
set -euo pipefail
swift --version
git status --short --branch
git log --oneline -10
```

Do **not** run `swift build` in initial cloud setup unless dependency network access is explicitly known to work in that environment.

## Primary task mode: PR review/fix loops

When asked to handle a PR loop:

1. Inspect PR state (`gh pr view`, checks, comments/reviews).
2. Classify findings:
   - **P0/P1:** fix if current and code-backed.
   - **P2:** fix only when low-risk and directly related.
   - **Stale:** mark with evidence from current HEAD.
3. Push scoped commits to the PR branch.

Do not chase tool scores (for example, “5/5”) blindly; prioritize current code-backed blocking issues.

## Change scope guardrail

Do **not** make docs-only changes unless the request or review finding explicitly asks for documentation updates.

## Verification expectations

- Prefer GitHub Actions macOS checks as mechanical build/test authority for native validation.
- If cloud Swift build/test is blocked by OS or network limits, report that explicitly and rely on PR checks.
- Do not claim real macOS UX verification from cloud runs (permissions prompts, system audio capture behavior, floating window behavior, typing latency).

## Safety constraints

- Never run `./scripts/dev-test.sh --clean`.
- Never delete MuesliDev data.
- Never reset app permissions.
- Never run release/preprod scripts unless explicitly requested.
