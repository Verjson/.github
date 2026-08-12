---
date: 2026-08-12
issue: 759
title: Complete the authorization check run when receipt verification fails
---

A failed arm-receipt verification now completes the `AI review authorization` check run with
`conclusion=failure` instead of leaving it `in_progress` forever, so a PR shows a red check it can
act on rather than blocking indefinitely with no signal.

`complete-authorization` carries `if: always()` precisely so it can report a gate failure, but its
step ran the arm receipt verifier under `set -euo pipefail` 52 lines before the PATCH that completes
the check run. Any non-zero exit from the verifier aborted the step there, so the check never left
`in_progress`, branch protection kept the PR blocked, and there was no failed run to rerun. The
workflow-token head lookup had the same shape, which meant an ordinary REST flake wedged a PR
identically. Observed on #758: check run `94125910988` was still pending 80 minutes after the gate
raised `arm run provenance mismatch`.

Both failures now set a status flag and fall through to complete the check, then exit non-zero. The
change is deliberately not a relaxation of authorization — an unverified receipt cannot reach
`conclusion=success`, and the approval `POST` is still never issued, which is the mutation the
original ordering was protecting. `scripts/ci-gate/complete-authorization.test.sh` previously
asserted the wedge as intended behaviour (`! grep -q 'api --method PATCH'`), conflating the approval
mutation with the failure report; it now requires the PATCH to happen with `conclusion=failure`
while the POST still does not. The verifier-invocation contract in
`scripts/ci-gate/event-driven-authorization.test.py` was line-anchored and is widened to admit the
new form while still requiring every sparse-checked-out verifier to be invoked through `bash`.

This is the amplifier behind the #757 trigger and outlives it: any future verifier failure would
have wedged every PR in the armed repositories the same way. Recorded as a dated correction on
[ADR 0081](../docs/decisions/0081-event-driven-terminal-ai-promotion/README.md).
