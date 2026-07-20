# Docs fast-lane recognizes NEXT/ fragments, not just NEXT.md — 2026-07-20

Fixes #66. The classify job's docs/community-health fast lane (which skips paid
AI review for documentation-only PRs) matched the literal `NEXT.md` but not
`NEXT/<fragment>.md`. Since the changelog moved to `NEXT/` fragments (#65), an
"ADR + NEXT/ fragment" PR failed the all-files allowlist and paid for a full
model review — a regression against the cost-reduction goal (this session's own
docs-only PRs hit it). The allowlist now matches `NEXT(\.md|/.*\.md)`, so
fragment PRs take the free deterministic lane again. Pinned by
`scripts/ci-gate/classify-fast-lane.test.sh` (extracts the real jq predicate from
the workflow; mutation-tested; wired into `actions-ci`).
