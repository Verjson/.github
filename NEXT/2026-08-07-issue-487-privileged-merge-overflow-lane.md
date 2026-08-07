---
date: 2026-08-07
title: Let the privileged merge poller reach the overflow lane its dispatcher already had
issue: 487
---

`ai-privileged-merge.yml`'s `runs-on` omitted `VERJSON_RUNNER_OVERFLOW`, so the escape hatch
ADR 0053 built for "jobs that poll the pool they wait on" was wired to the cheap dispatcher
and withheld from the ~40-minute poller — the job 0053's own table measures at 29% of lane
runtime, and the one whose file says of itself, two lines above its poll loop, that it "polls
the SAME pool as the CI it waits for" (#363).

Both ADRs that deferred this named the precondition, and both are now met: ADR 0053 excluded
it because every generated caller passed `inputs.runner_labels` (a premise 0053 itself already
annotates as superseded by ADR 0057 / #405), and ADR 0056 called it "probably the right
permanent fix" pending #341's re-scope, which landed in `c60770c`. Found from the adopter side
in `Verjson/verjson-ai#180`. Rationale is in
[ADR 0064](docs/decisions/0064-privileged-merge-reaches-the-overflow-lane/README.md).

- **No caller is regenerated and no precedence inverts.** Overflow heads the *lane tail*, not
  the whole chain, so `inputs.runner_labels` still wins outright. A caller generated before
  #405 is bit-for-bit unaffected; only lane-routed callers reach the new term. That is exactly
  the inversion ADR 0053 refused, and it is now pinned by an assertion rather than by prose.
- **The test discovers polling jobs rather than listing them.** #487 existed *because* ADR
  0042 split this job into its own file and the overflow term did not follow it; a hardcoded
  pair list would have carried the same blind spot. The sweep in
  `runner-routing-policy.test.sh` requires both halves of the real hazard — the job parks on a
  `sleep`, **and** parks on checks it does not run — because the circularity is the deadlock.
- **`sleep` alone over-matches, and the false positive is live.** The loose form flagged
  `node-ci.yml`'s `build-test`, which sleeps waiting for its own Docker Postgres. That wait
  needs no runner and starves nothing; routing the fleet's CI onto hosted overflow would have
  been a much larger decision reached by accident. The first draft of this test did exactly
  that before the predicate was narrowed.
- **The watchdog stays, and `fleet-watchdog.yml`'s comment is corrected in the same commit.**
  It asserted that overflow "does NOT cover `ai-privileged-merge.yml`", which this change
  makes false. The residual exposure narrows rather than vanishing — pre-#405 callers still
  route onto the pool by label — so ADR 0056 is not reversed.
