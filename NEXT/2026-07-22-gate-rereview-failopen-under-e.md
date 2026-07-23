# Merge gate: re-review skip must fail open under `bash -e` — 2026-07-22

The re-review-skip step (ADR 0019, #120) aborted the required `gate` job on
first-review PRs, blocking all merges org-wide (#124): GitHub runs `run:` under
`bash -eo pipefail`, and the step's `set -uo pipefail` never cleared that `-e`,
so the `grep` for a (nonexistent) prior marker returned 1 and errexit killed the
step. Fixed with an explicit `set +e` so the decision degrades to "review" on any
non-zero. `scripts/ci-gate/rereview-skip.test.sh` now runs the extracted block
under `bash -eo pipefail` (matching GitHub) — mutation-verified it catches the
abort. Amends [ADR 0019](docs/decisions/0019-gate-skips-rereview-on-unchanged-diff/README.md).
