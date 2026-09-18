---
date: 2026-09-18
issue: 1476
impact: patch
title: Treat an unanswerable freshness compare as indeterminate instead of "not behind"
---

The merge gate no longer merges on a possibly stale base when it cannot establish that
the base is current. An unanswerable `compare` request — the call failing, returning an
empty body, or returning a body that is not a number — used to collapse into `behind=0`
and read as a genuine "this head is not behind", so an API outage, a rate limit or an
auth blip let the gate proceed on a review taken against a stale base, with silence as
the only signal. The lookup now distinguishes a real answer from no answer, retries three
times so a transient blip still self-heals, and then holds with a stated `::error::`
rather than proceeding.

Fixes [#1476](https://github.com/Verjson/.github/issues/1476). The decision and its
fleet-wide blast radius are recorded in
[ADR 0195](../docs/decisions/0195-an-indeterminate-authorization-answer-is-not-a-permissive-one/README.md).

`scripts/ci-gate/freshness.test.sh` pins each indeterminate shape separately — errored,
empty and unparseable — and asserts the bounded retry both recovers a transient blip and
genuinely re-asks before holding. Fixing that test exposed a defect in its own harness:
the awk block that extracts the freshness step latched and appended every later `run:`
block in the workflow, so the extracted "step" was 103 lines of freshness followed by the
rest of the file, and an exit status asserted against it could belong to unrelated
trailing code. The extractor now stops at the step boundary.

#1476 also required auditing every `2>/dev/null ||` default in the workflow rather than
only the reported one. All 24 sites were traced to what consumes them: 13 are
decision-bearing but fail closed, 10 cannot move a decision at all, and one remains
decision-bearing and fail-open — the Renovate release-age lookup, where a failed request
yields `age_pending=0` and the PR enters the normal review lane instead of deferring.
That one is tracked separately; its blast radius is a wasted review rather than a merge
on an unverified base.
