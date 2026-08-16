# 0104 — Trusted automation attributes hosted Renovate changes

- **Date:** 2026-08-16
- **Issue:** [Verjson/.github#834](https://github.com/Verjson/.github/issues/834)
- **Related:** [Verjson/renovate-config#32](https://github.com/Verjson/renovate-config/issues/32), [ADR 0038](../0038-canonical-changelog-contract/README.md), [ADR 0099](../0099-release-app-replaces-admin-pat/README.md)
- **Category:** privileged write / authentication (sensitive class)

## Context

The canonical changelog contract intentionally has no actor exception: a
dependency manifest or lockfile change must add release context in `NEXT/`.
Hosted Renovate cannot create that fragment itself because its generated branch
has no repository credential, so every otherwise valid dependency update is
blocked by `check-pr`. Consumer-side exceptions or handwritten bot workflows
would weaken and fragment the organization contract.

An ordinary `pull_request` workflow cannot write the bot branch. A
`pull_request_target` workflow can use base-branch credentials, but executing or
checking out pull-request-head code in that event would cross the secret trust
boundary. `GITHUB_TOKEN` pushes also suppress the follow-up workflow events that
must validate the new commit.

## Decision

Add a generated, immutable `pull_request_target` caller and a trusted reusable
workflow in `Verjson/.github`. The caller is read-only and delegates at one
40-character contract SHA. The reusable workflow checks out only
`Verjson/.github` at its executing `job.workflow_sha`, and rejects a
`contract_ref` that differs from that SHA; it never checks out or executes
consumer PR-head code.

Admission is fail-closed and repeated against the live pull request. The PR must
be open, same-repository, authored by `app/renovate` or `renovate[bot]`, target
the triggering base, retain the exact triggering head, and use a normalized
`renovate/*` branch. Its body must contain exactly one structurally valid
Renovate update table with bounded, safe package and version fields. A valid
fragment newly added by the PR makes the workflow a no-op only when it declares
an explicit `major`, `minor`, or `patch` impact.

Only after planning requires a write does the workflow mint the dedicated
Release App token from ADR 0099. The request is limited to the current
repository and Contents write. PR metadata, changed files, and file contents
are read only with the job token's explicit `pull-requests: read` and
`contents: read` grants; the App token is never used for PR reads. A trusted
Python helper uses the App token only for Git Data API reads and mutations: it
creates one blob, tree, and commit whose sole parent is the admitted head, then
updates that exact head ref with `force: false`. It revalidates the live PR,
update table, added fragments, and ref immediately before mutation. A moved
head, malformed body, path collision, fork, different author, or different
branch fails without writing.

The fragment is
`NEXT/YYYY-MM-DD-issue-<pr>-renovate-dependencies.md`, records every parsed
package with its from/to version, and declares patch impact. The App-authored
push emits the normal `synchronize` event, so the canonical changelog and CI
checks evaluate the resulting head. The generated contract test verifies the
caller pin, event, credential mapping, and least privilege whenever adopters
move the contract SHA.

## Consequences

- Consumers adopt one generated caller through the same immutable-pin path as
  the workflow, renderer, and contract test; no local exception is supported.
- The workflow handles only Renovate's reviewed table shape. A new upstream body
  format fails closed until the canonical parser and tests deliberately change.
- The Release App private key remains organization-scoped as documented in ADR
  0099. The minted token is repository-scoped, but any trusted base workflow in
  a repository where that organization secret is available remains within the
  credential's existing trust boundary.
- First adoption requires the generated caller to land on the base branch. A
  subsequent representative Renovate PR is the live canary for fragment push
  and follow-up validation.

## Rollback

Regenerate adopters at the prior immutable contract SHA or remove only the
generated attribution caller. Revert the canonical workflow and helper. Existing
fragments and changelog history remain valid and are not deleted.
