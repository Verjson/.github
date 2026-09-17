---
date: 2026-09-17
issue: 1409
title: Adjudicate the scheduled arm audit's findings against a reviewed expectation
impact: minor
---

The scheduled authorization-arm audit reported only into its own run log. It
ships deliberately red — `Verjson/verjson-agents` is armed with no deterministic
required CI behind it (#1401, #1407) — so a genuinely new finding and the known
one produced the same signal, and telling them apart meant opening the run.

The arm audit's verdict is now the comparison of its findings against
`config/audit-expected-findings.json` rather than its raw exit status. A recorded
finding is quiet, an unrecorded one is loud, a recorded one that stops
reproducing is loud, and a recorded acknowledgement expires. Changing what is
quiet is a reviewed diff against that file, and every verdict renders its
classified digests into the job summary.

Nothing fails open. The comparison is over the exact finding text, each entry's
digest must equal SHA-256 of its own recorded text, and an audit that crashed
without reporting, an audit that exited zero while reporting, a missing or
malformed expectation, and an unrecorded audit name all exit 2 under ADR 0024
rather than reporting a match. The committed expectation is validated in the
`platform` CI group, so a malformed edit fails in the pull request.

`scripts/audit-finding-state.py` is audit-agnostic; the sibling scheduled jobs
can adopt it by adding an `audits` key and wrapping their command. ADR 0189
records the decision and why the issue's proposed issue-per-finding mechanism was
not chosen as the primary signal.

The adjudicator's two guards constrained findings against a zero and a non-zero
exit, but neither constrained *which* non-zero. An audit that printed the
recorded finding and was then killed satisfied both and was adjudicated `match`,
exit 0 — a hub-privileged control reporting conformance from a run that never
finished, which is the ADR 0024 fail-open it exists to close. A wrapped audit now
declares the statuses it uses with `--expect-status`, defaulting to 0 and 1, and
any other status is undetermined. The arm audit's own invocation declares them
explicitly rather than relying on the default.

Wrapping an audit also removed its output from the job log: its stdout was
captured and dropped, so the structured result `ai-review-required-workflow-audit.py`
prints no longer appeared anywhere. It is now written through to stderr, leaving
stdout for the adjudicator's own JSON. An empty command fails closed as
undetermined rather than raising `IndexError` and exiting 1 as drift.

The control-character scrub's test exercised nothing: its fixture used a carriage
return, which `splitlines()` discards before the scrub can run, so the test passed
with the scrub deleted. It now uses an escape character and asserts the
replacement character appears.
