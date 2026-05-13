# ADR 0008 — Build-first, draft-PR-later

- Date: 2026-05-13
- Status: Accepted

## Context

The execution prompt asks us to land a working v0 implementation in a single
autonomous session, then hand it back for human review. We can either:

1. Push the branch as a draft PR immediately so reviewers can comment as
   they read each commit.
2. Land the work locally with green tests and a clean diff, then surface a
   draft PR only after the human reviewer has read the final report.

## Decision

**Build first, draft-PR later.** The session writes commits to the local
`feat/auto-capture-v0` branch with each commit individually green
(`swift test --package-path native/MuesliNative` passes and
`MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh` builds). The session **does not
push** to `origin` and does not open a draft PR.

Rationale:

- The reviewer is the same person who launched the session. They prefer a
  finished local state over GitHub-side noise.
- Pushing early before the reviewer has read the final report risks
  premature CI runs and code-review-bot pings on incomplete intermediate
  commits.
- Reverting an un-pushed branch is a single `git reset --hard`; reverting a
  pushed branch is louder and may pull in review bots that already left
  comments.

## Consequences

- The final reviewer sees a clean, sequential commit history when they open
  the PR themselves.
- CI does not run until the reviewer pushes (saves minutes on shared
  runners during early iteration).
- If we discover a blocker mid-session we have not "poisoned" the public
  branch with a half-built PR.
