---
date: 2026-09-18
issue: 1448
title: Reset privileged-merge conformance state before any branch leaves the iteration
impact: patch
---

`scripts/privileged-merge-conformance.sh` evaluated each repository inside one loop
whose per-repository `unset` sat at the **bottom** of the body, after seven branches
that can leave the iteration early. The 40-hex caller-pin guard was the one branch
that reached that exit while the repository was already inventoried as a consumer, so
it both skipped the reset and skipped the repository's own organization-secret check:
a consumer with an unusable pin was never asked whether it can read
`MERGE_APP_PRIVATE_KEY`, and the next repository began its verdict on the previous
one's values.

The fix is the restructure the issue asked for rather than the review's suggested
remedy. Dropping the `continue` would have interpolated the rejected pin into the
`gh api compare` call the guard exists to prevent, so the pin-dependent work is now
conditional — a third `elif` arm beside the existing "expected exactly one pin"
arm — and the reset moved to the top of the loop body, where it is unconditional
with respect to every early exit rather than only the one named in the issue.

Audited exits, in loop order: the blank-inventory guard (sets no state), unreadable
repository metadata, invalid repository metadata, a 404 caller for a non-direct
consumer, an unreadable caller for a non-direct consumer, undecodable caller content
for a non-direct consumer, and the 40-hex pin guard. All seven skipped the old
bottom reset. Only the pin guard also skipped a check the repository had earned;
the four caller-fetch exits deliberately skip the secret check, because secret
visibility is not consumer registration, and that behavior is preserved.

`metadata`, `default_branch`, `visibility_type`, and `has_secret` had the same leak
shape and were never in the reset list at all; they are now. `$tmp/historical-generator.sh`
shares one path across iterations but is rewritten immediately before each use inside
the same iteration, so it is reported clean rather than changed.

The guard cannot fire against the current extractor, whose capture group is literally
`([0-9a-f]{40})` — it exists to survive that extractor changing. The new test makes
exactly that change to a copy of the script and runs an ordered three-repository
fleet: `Verjson/alpha` populates every loop-scoped variable with a conforming value,
`Verjson/beta` then trips the guard while holding no secret access, and
`Verjson/.github` follows. Restoring the `continue` reddens it through
`Missing privileged merge App key access::repository=Verjson/beta`. The remaining
six exits have no reachable read-before-assignment, so no fixture can observe them;
the invariant that keeps them unobservable is pinned structurally instead, and
returning the reset to the bottom of the loop reddens that assertion.
