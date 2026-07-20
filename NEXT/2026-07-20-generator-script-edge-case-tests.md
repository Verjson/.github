# Fixture-based edge-case tests for the generator scripts — 2026-07-20

Closes #67. `scripts/gen-adr-index.sh` and `scripts/render-next.sh` were only
exercised by their live `--check`/smoke-run in CI, which catches drift but not
edge cases with a clear pass/fail. Added `scripts/ci-gate/gen-adr-index.test.sh`
and `scripts/ci-gate/render-next.test.sh` — each copies the **real** script into
a stubbed fixture tree (single source of truth, can't drift) and asserts the
fail-fast paths (ADR dir with no README, malformed `**Date:**`, missing index
markers, missing/empty `NEXT/`) plus the happy paths (reverse-sorted index,
`--check` staleness detection, newest-first render with README excluded and
`0000-archive` last). Wired into `actions-ci`, matching the per-script
`scripts/ci-gate/*.test.sh` convention.
