# 0202 — Bind autonomous merge to an independent-review receipt

- **Date:** 2026-09-23
- **Status:** Accepted
- **Issue:** [Verjson/.github#1383](https://github.com/Verjson/.github/issues/1383)
- **Amends:** [ADR 0098](../0098-require-bounded-ai-review-for-code/README.md), [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)
- **Category:** merge authorization (sensitive class)

## Context

The automated AI review and exact-head authorization are necessary but do not record the
independent reviewer pass required by autonomous delivery. Pull requests #1373 and #1375
both completed their App-owned AI authorization before the terminal merge App merged them,
while their independent reviewer passes were still running. No defect reached `main`, but
the procedural review requirement was not part of the merge authorization.

Adding another GitHub App would create identity and key-custody work unrelated to the
missing evidence. GitHub pull-request reviews already provide a review ID, author,
submitted commit, state, and body. Existing maintainers can publish an adjudicated
independent-review result through that surface without granting a new principal authority.
Review bodies and states are mutable, so one read is not durable authorization evidence.

## Decision

Every autonomous terminal merge requires one exact marker line in a `COMMENTED` review:

`<!-- independent-review:v1 pr:<number> head:<40-hex-head> verdict:approved -->`

The terminal merge workflow treats the newest exact-head review from an organization member,
owner, or collaborator account as the governing independent-review verdict. It accepts that
review only when its live state is `COMMENTED`, its entire trimmed body is the canonical
approval marker, its actor is a non-App `User`, and the actor's live repository role is
`maintain` or `admin`. A later `CHANGES_REQUESTED`, `DISMISSED`, withdrawn, edited, or
otherwise non-canonical review supersedes an earlier approval and blocks autonomous merge.

Immediately before merge-token minting, the workflow re-fetches the selected review by ID,
re-lists reviews to prove no later exact-head verdict appeared, and re-reads current actor
permission. Association hints alone are insufficient. A missing, malformed, stale-head,
App-authored, superseded, or insufficiently authorized receipt fails closed before the merge
App token is minted.

The receipt records the central PM's adjudication of an independent reviewer result. It
does not replace the automated provider review, dedicated App approval, required CI,
hold/draft checks, or live-base validation. It also does not change the protected human
merge path: the additional evidence is consumed only by the autonomous privileged workflow.

The publisher uses an existing independently authorized non-App account and the ordinary
pull-request review API. GitHub's `User` account type does not prove a human operator: it can
also represent an account driven through a PAT or other service automation. The trust claim
is therefore limited to a current maintain/admin account distinct from the merge and review
Apps; it is not a proof of human presence. No App permission, private key, ruleset bypass, or
live identity mutation is added. Changing the PR head invalidates the receipt by construction
and requires a new independent review and receipt.

GitHub does not offer an atomic transaction spanning review reads, permission reads, App-token
minting, and merge. Terminal revalidation narrows that race to the calls immediately before
token minting; a hold remains the operator-controlled emergency revocation mechanism during
that residual interval, and the merge path independently rechecks the live head and base.

## Consequences

- The merge App cannot race an in-flight independent reviewer pass.
- Receipt publication plus terminal revalidation is an explicit handoff from reviewer
  adjudication to merge automation.
- A maintainer can deliberately attest a result dishonestly, but that principal already
  controls the protected human merge path; this design adds no new authority.
- Provider approval without an independent-review receipt leaves autonomous promotion red
  and the pull request open for correction or an authorized human merge.

## Verification

`scripts/ci-gate/native-automerge.test.sh` exercises the valid receipt and rejects absent,
stale-head, foreign-PR, fenced, surrounding-context, edited, dismissed, withdrawn,
later-negative, later-created, App-authored, and permission-downgrade variants.
