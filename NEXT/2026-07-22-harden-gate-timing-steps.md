# Harden merge-gate runner-timing diagnostics against bad timestamps — 2026-07-22

The two diagnostic steps in `ai-review-merge.yml` ("Record preflight runner
timing" and "Record gate runner timing") computed a queue delta with bash
arithmetic over `date -d` output. A non-empty but unparseable timestamp made
`date -d` emit nothing, turning the expression into `$(( N -  ))` — a fatal
arithmetic syntax error under `set -uo pipefail` that aborted the required
preflight/gate job, contradicting ADR 0017's promise that these diagnostics
never change enforcement. Each `date -d` is now captured with `|| true` and the
delta is computed only when both epochs match `^[0-9]+$`, degrading a bad or
empty timestamp to the existing "unknown" notice instead of aborting. Covered by
`scripts/ci-gate/preflight-timing.test.sh` (extraction-based, wired into
`actions-ci.yml`). Ref issue #106; amends ADR 0017.
