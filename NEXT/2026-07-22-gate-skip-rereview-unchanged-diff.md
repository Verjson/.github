# Merge gate skips the paid re-review on a base-merge-only re-fire — 2026-07-22

Under active `main`, `preflight` keeps base-merging a green PR, which re-fires
`synchronize` and re-pays a full AI review even though the PR's own net diff is
unchanged — burning $ and widening the window that thrashes the required check
red (observed on #114). The `gate` job now computes the PR's net patch-id
(`git patch-id --stable` over `git diff <merge-base> HEAD`) and embeds it in the
approval marker: `<!-- ai-review-head:SHA patchid:PID model:M -->`. On a re-fire
it compares the current patch-id against the most recent **approval** marker's
patchid and, on a non-empty exact match, skips the model and reuses a
synthesized approved verdict — the unchanged authoritative merge-recheck still
re-verifies head/CI/hold/draft and does the squash, so correctness is unchanged.
Every ambiguous case (no merge-base, empty diff, missing/old/blocking-only
marker, different patch-id) falls through to the full review. Pinned by
`scripts/ci-gate/rereview-skip.test.sh` + `review-comment.test.sh` (wired into
`actions-ci`). See
[ADR 0019](docs/decisions/0019-gate-skips-rereview-on-unchanged-diff/README.md),
issue #120.
