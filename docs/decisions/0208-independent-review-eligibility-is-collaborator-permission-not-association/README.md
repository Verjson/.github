# 0208 — Independent-review eligibility is the live collaborator permission, not `author_association`

- **Date:** 2026-09-26
- **Status:** Accepted
- **Issue:** [Verjson/.github#1615](https://github.com/Verjson/.github/issues/1615)
- **Amends:** [ADR 0202](../0202-bind-autonomous-merge-to-independent-review-receipt/README.md)
- **Category:** merge authorization (sensitive class)

## Context

ADR 0202 requires `ai-privileged-merge.yml`'s independent-review revalidation to accept a
candidate review only when, among other conditions, its `author_association` is `OWNER`,
`MEMBER`, or `COLLABORATOR`. `Verjson/verjson-ai` PR #695 reproduced a case where a review
satisfying every documented condition — exact head, `COMMENTED` state, canonical marker
body, a `User` actor holding live `maintain` role — was still rejected with "an exact-head
independent-review verdict is required before autonomous merge".

`author_association` is computed relative to the *calling token's* visibility into
organization membership, not the reviewer's actual standing. The revalidation step calls
the GitHub API with `github.token` (the job's default `GITHUB_TOKEN`), which lacks
`read:org` visibility into private organization membership. For a reviewer whose `Verjson`
membership is private, that token resolves `author_association` as something other than
`MEMBER` even though a personal token belonging to an actual org member correctly resolves
it as `MEMBER`. The gate accordingly fails closed on every legitimate member/owner review
whenever the automation's own token cannot see that membership — a false negative, not a
security question answered "no".

The revalidation already performs a separate, live, and strictly more direct check: it
looks up the reviewer's current repository role via
`repos/{repo}/collaborators/{user}/permission` and requires `admin` or `maintain`, both
before selecting a candidate and again immediately before authorizing merge. That check
does not depend on organization-membership visibility — it asks GitHub directly what
permission this specific user holds on this specific repository — and was already the
trust anchor ADR 0202 relied on for the "governing account" requirement.

## Decision

Drop `author_association` as a gating condition from all three places
`ai-privileged-merge.yml`'s independent-review step used it: the initial candidate search,
the live-review body/state revalidation, and the later-review supersession check. The
remaining conditions — exact head SHA, `user.type == "User"`, a well-formed login, exact
`COMMENTED` state, an unedited canonical marker body, and the unconditional live
`admin`/`maintain` collaborator-permission check before and after selection — remain the
full eligibility test, and are sufficient on their own: they already establish that the
review came from a real (non-bot) account that currently holds `admin` or `maintain` on
the exact repository being merged into, for the exact head being merged, with an unedited,
non-superseded approval marker.

This does not widen who can authorize a merge. `author_association` was a coarse,
unreliable proxy for exactly the same fact the collaborator-permission check already
verifies directly and unconditionally; removing it removes a redundant check that could
silently fail closed, not a security boundary.

## Consequences

- An autonomous merge no longer depends on the automation token's ability to resolve a
  reviewer's private organization membership. It depends only on that reviewer's live
  repository permission, which any token with repository read access can query correctly.
- No change to who is eligible: every review previously accepted (an `OWNER`/`MEMBER`/
  `COLLABORATOR` account that also passed the `admin`/`maintain` permission check) is still
  accepted, because the permission check was already mandatory and unconditional.
- `Verjson/.github/scripts/ci-gate/native-automerge.test.sh` gained a regression case
  asserting that a review with an unresolvable `author_association` (`"NONE"`) still
  promotes when the live permission check confirms `admin`/`maintain`.
