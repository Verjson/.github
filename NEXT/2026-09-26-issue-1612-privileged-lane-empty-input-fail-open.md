---
date: 2026-09-26
issue: 1612
impact: patch
title: Close the privileged-lane admission gate's empty/whitespace-input fail-open under jq 1.6
---

`ai-privileged-merge.yml`'s `validate_privileged_lane` job — the
credentialless admission gate a later job's scheduling-time `if:`
independently rechecks before scheduling on self-hosted capacity (ADR 0117 /
ADR 0118) — fed `PRIVILEGED_LANE` to `jq -e` through a bash here-string
(`<<<"${PRIVILEGED_LANE:-}"`). A here-string always appends a trailing
newline, so an unset, empty, or whitespace-only input reached jq as a
stream with no JSON values. jq 1.6 treats that as "the filter never ran"
and exits `0` regardless of `-e`, unlike a real parse error or a
`null`/`false` result — so the step printed "privileged_lane validated:
exact match" and returned success for exactly the input shape this step
exists to catch first.

This did not enable a live privilege escalation: `privileged_merge`'s own
scheduling-time `if:` independently compares `inputs.privileged_lane` to
the literal string `["ubuntu-24.04"]`, with no dependency on jq, and that
comparison correctly stayed false for an empty/whitespace input regardless
of this step's bug — the ADR's two-gate design contained the practical
impact. The credentialless admission step is still expected to fail closed
on its own, which is why this is a fix rather than a no-op.

Fixed by requiring both `jq -e`'s exit status and its stdout to equal the
literal string `"true"` before treating the input as validated. Either
signal alone is unreliable: `-e`'s exit status is what fails open on a
zero-value stream (the original bug), while bare stdout is fooled by the
mirror case — a valid value followed by trailing garbage, where jq emits
`"true"` for the first parsed value before failing on the unparsed
remainder. `scripts/ci-gate/privileged-lane-validation.test.sh` gained
regression cases for both the whitespace-only and trailing-garbage shapes
alongside its existing missing-input case; all ten assertions pass. ADR
0118 is amended with a dated correction rather than superseded, since this
restores an invariant its own Security analysis already states.
