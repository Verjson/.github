---
date: 2026-09-18
issue: 1476
impact: patch
title: Hold the merge gate when freshness cannot be established, instead of proceeding
---

The merge gate no longer merges on a possibly stale base when it cannot establish that
the base is current. Two separate reads in the freshness step could previously leave it
unable to establish that and proceed anyway; both now hold.

An unanswerable `compare` request — the call failing, returning an
empty body, or returning a body that is not a number — used to collapse into `behind=0`
and read as a genuine "this head is not behind", so an API outage, a rate limit or an
auth blip let the gate proceed on a review taken against a stale base, with silence as
the only signal. The lookup now distinguishes a real answer from no answer, retries three
times so a transient blip still self-heals, and then holds with a stated `::error::`
rather than proceeding.

The second read is the PR metadata lookup, which runs *before* the compare. When its
three bounded attempts all failed it emitted a warning and proceeded without evaluating
freshness at all — so during a total API outage the gate proceeded and the hardened
compare check above was never reached, leaving it unreachable on exactly the path it was
written for. It now holds with a stated `::error::` as well.

Fixes [#1476](https://github.com/Verjson/.github/issues/1476) and
[#1496](https://github.com/Verjson/.github/issues/1496). The decision and its
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
only the reported one. That pattern occurs on 25 lines (26 occurrences; one line chains
two `git fetch` fallbacks), one of which is the compare site fixed here. The other 24 were
traced to what consumes them: 13 are
decision-bearing but fail closed, 10 cannot move a decision at all, and one remains
decision-bearing and fail-open — the Renovate release-age lookup, where a failed request
yields `age_pending=0` and the PR enters the normal review lane instead of deferring.
That one is tracked separately; its blast radius is a wasted review rather than a merge
on an unverified base.

## Also: the AI review authorization race ([#1480](https://github.com/Verjson/.github/issues/1480))

The same mistake in the opposite direction. `verify-zero-provider-recovery.sh` decided
direct-review admission with one predicate over the paginated `workflow_dispatch` run
listing, and reported its failure with one message, `initial direct review dispatch is
missing or not unique`. That message covered three unrelated conditions: the run not yet
appearing in the listing (eventual consistency on `GET /actions/runs`), a genuine
duplicate dispatch, and a non-1 `run_attempt`. A not-yet-indexed run and a duplicated run
produced byte-identical output, so a spurious red on this required check could not be
triaged from its log.

The conditions are now separated and handled according to whether they self-heal. An
absent run is bound-retried, five polls with a 3-second gap, because it is eventually
consistent. A duplicate is refused on the first look and never retried — retrying it
would only widen the window in which a second dispatch could be accepted as the trusted
one. Neither assertion is relaxed: more than one match and a non-1 `run_attempt` both
still fail closed, and each of the four conditions now names itself.

`scripts/ci-gate/zero-provider-recovery.test.sh` asserts the distinctness rather than
merely that each case still fails, and counts the polls to pin which conditions are
retried and which are refused immediately.
