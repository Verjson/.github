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
looks up a candidate's current repository role via
`repos/{repo}/collaborators/{user}/permission` and requires `admin` or `maintain`. That
check does not depend on organization-membership visibility — it asks GitHub directly what
permission a specific user holds on a specific repository — and was already the trust
anchor ADR 0202 relied on for the "governing account" requirement.

## Decision

Drop `author_association` as a gating condition from `ai-privileged-merge.yml`'s
independent-review step, and fold the live `admin`/`maintain` permission check directly
into candidate selection instead of running it once after selection.

`Verjson/.github` is a public repository, so removing `author_association` means any
GitHub account can leave a review at the exact head SHA — picking whichever candidate has
the highest review ID, unconditionally, would let such a review supersede or block a real
approval if posted with a later ID. Selection is therefore one shared function
(`select_privileged_candidate`), used both for the initial pick and for the later
supersession recheck, that walks reviews matching `commit_id == <exact head>`,
`user.type == "User"`, and a well-formed login, from the **highest review ID down**, and
accepts the **first** whose account currently holds live `admin` or `maintain` — skipping,
not failing on, any higher-ID review that doesn't. The live-review step separately
requires the accepted candidate's exact `COMMENTED` state and an unedited canonical marker
body.

This does not widen who can authorize a merge. `author_association` was a coarse,
unreliable proxy for exactly the fact the collaborator-permission check already verifies
directly; the walk-and-skip selection means an unprivileged account's review can no longer
even interfere with a real approval's selection, which is strictly narrower than the
previous design allowed on a public repository.

The walk itself is bounded (`MAX_CANDIDATE_LOOKUPS`, currently 20): without a cap, a flood
of junk reviews posted above the real approval would force an unbounded number of live
`collaborators/{user}/permission` lookups per authorization attempt. Reaching the cap
before finding a privileged candidate fails closed exactly like finding no candidate at
all, trading a small, predictable availability cost (a merge that needs a manual
`--admin` fallback if a PR is ever flooded with 20 or more candidate reviews above the
real one) for a bounded worst-case request count instead of an unbounded one.

## Consequences

- An autonomous merge no longer depends on the automation token's ability to resolve a
  reviewer's private organization membership. It depends only on a candidate's live
  repository permission, which any token with repository read access can query correctly.
- No change to who is eligible: every review previously accepted (an `OWNER`/`MEMBER`/
  `COLLABORATOR` account that also passed the `admin`/`maintain` permission check) is still
  accepted, because the permission check was already mandatory.
- A review from an account that is not a current `admin`/`maintain` collaborator can no
  longer block or supersede a real approval merely by carrying a higher review ID, even
  though anyone can post such a review on a public repository — closing a griefing/denial-
  of-service surface the naive "drop `author_association`, keep picking the highest ID"
  version of this fix would otherwise have introduced.
- `scripts/ci-gate/native-automerge.test.sh` gained regression cases: a review with an
  unresolvable `author_association` (`"NONE"`) still promotes when the live permission
  check confirms `admin`/`maintain`; a higher-ID review from a non-privileged account
  cannot block or supersede a real approval's selection; and flooding the exact head with
  more non-privileged candidates than `MAX_CANDIDATE_LOOKUPS` fails closed within a
  bounded number of permission lookups rather than searching indefinitely.
