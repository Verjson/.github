# Merge gate treats absent CI checks as not-green — 2026-07-25

Closes the second, deeper defect in #143: the gate concluded "CI green" whenever
nothing in the filtered `statusCheckRollup` was pending — which is also true when
the rollup is **empty**. A workflow that dies with `startup_failure` produces no
check run at all, so a PR that was never built, tested or linted looked identical
to a fully green one and was auto-merged.

`ci_wait` now (a) never calls an empty rollup green — it keeps polling and ends the
window with `::error::phase=ci-wait result=no-checks` plus the remediation, never a
silent hang; (b) probes `actions/runs?head_sha=…` before concluding green and fails
closed naming any `startup_failure` workflow; (c) treats an unreadable probe as
inconclusive (`result=probe-unavailable`), never green; and (d) fails fast on an
empty head SHA (`result=unknown-head`) so an unfiltered runs query can't blame this
PR for another commit's failure. The authoritative merge recheck repeats both
absence checks — it is the step that actually squash-merges. The
`SUCCESS`/`NEUTRAL`/`SKIPPED` allowlist, `renovate/stability-days` handling, and the
fast/ai attempt ceilings are unchanged.

Covered by `scripts/ci-gate/ci-wait-fail-closed.test.sh` (wired into `actions-ci`);
two older fixtures that used an empty rollup as a stand-in for "green" now carry a
real passing check. Rationale in ADR 0024. The startup-failure trigger itself was
already fixed in e3cf463/b2e57be — untouched here. Refs #143, ADR 0024.
