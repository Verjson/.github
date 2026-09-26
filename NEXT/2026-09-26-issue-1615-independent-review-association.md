---
date: 2026-09-26
issue: 1615
impact: patch
title: Stop gating independent-review eligibility on author_association, an org-membership signal the automation token cannot reliably resolve
---

`ai-privileged-merge.yml`'s independent-review revalidation required a candidate
review's `author_association` to be `OWNER`, `MEMBER`, or `COLLABORATOR`.
`author_association` reflects the *calling token's* visibility into organization
membership, not the reviewer's actual standing. The step authenticates with the
job's default `GITHUB_TOKEN`, which lacks `read:org` visibility into private
organization membership, so a real `Verjson` member with private membership
visibility resolved as something other than `MEMBER` from that token's
perspective — silently rejecting a correctly marked, exact-head, live-`maintain`
review with "an exact-head independent-review verdict is required before
autonomous merge" (`Verjson/verjson-ai` PR #695).

Dropping `author_association` outright would have introduced a new gap:
`Verjson/.github` is a public repository, so any GitHub account can leave a
review at the exact head SHA, and picking whichever candidate has the highest
review ID unconditionally would let such a review block or supersede a real
approval posted earlier. Selection is now one shared function
(`select_privileged_candidate`) that walks candidates from the highest review ID
down and accepts the first whose account currently holds live `admin` or
`maintain` — skipping, not failing on, a higher-ID review that doesn't — used
both for the initial pick and the later supersession recheck. The live
`admin`/`maintain` permission check (`repos/{repo}/collaborators/{user}/permission`)
was already the trust anchor ADR 0202 relied on; it is now part of selection
itself rather than a separate step run once after selection.

The walk is bounded (`MAX_CANDIDATE_LOOKUPS`, currently 20): a flood of junk
reviews posted above the real approval fails closed within a bounded number
of live permission lookups rather than searching indefinitely.

`scripts/ci-gate/native-automerge.test.sh` gained regression cases: a review
whose `author_association` is `"NONE"` still promotes when the live
`admin`/`maintain` permission check confirms eligibility; a higher-ID review
from a non-privileged account can no longer block or supersede a real
approval; and flooding the exact head with more non-privileged candidates
than the bound fails closed with a bounded lookup cost. See
[ADR 0208](../docs/decisions/0208-independent-review-eligibility-is-collaborator-permission-not-association/README.md),
which amends ADR 0202.
