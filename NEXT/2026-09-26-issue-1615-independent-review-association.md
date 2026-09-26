---
date: 2026-09-26
issue: 1615
impact: patch
title: Stop gating independent-review eligibility on author_association, an org-membership signal the automation token cannot reliably resolve
---

`ai-privileged-merge.yml`'s independent-review revalidation required a candidate
review's `author_association` to be `OWNER`, `MEMBER`, or `COLLABORATOR` in three
places: the initial candidate search, the live-review revalidation, and the
later-review supersession check. `author_association` reflects the *calling
token's* visibility into organization membership, not the reviewer's actual
standing. The step authenticates with the job's default `GITHUB_TOKEN`, which
lacks `read:org` visibility into private organization membership, so a real
`Verjson` member with private membership visibility resolved as something other
than `MEMBER` from that token's perspective — silently rejecting a correctly
marked, exact-head, live-`maintain` review with "an exact-head independent-review
verdict is required before autonomous merge" (`Verjson/verjson-ai` PR #695).

The same revalidation already performs a separate, live, and strictly more direct
check: `repos/{repo}/collaborators/{user}/permission`, required to be `admin` or
`maintain`, both before candidate selection and again immediately before
authorizing merge. That check does not depend on organization-membership
visibility and was already the trust anchor ADR 0202 relied on. Dropping the
redundant `author_association` gate does not widen who can authorize a merge —
every review previously accepted still passes the unconditional permission
check, which was already mandatory.

`scripts/ci-gate/native-automerge.test.sh` gained a regression case: a review
whose `author_association` is `"NONE"` still promotes when the live
`admin`/`maintain` permission check confirms eligibility. See
[ADR 0208](../docs/decisions/0208-independent-review-eligibility-is-collaborator-permission-not-association/README.md),
which amends ADR 0202.
