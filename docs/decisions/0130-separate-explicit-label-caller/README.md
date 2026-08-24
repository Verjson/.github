# 0130 — Separate explicit review labels from the required-workflow trigger

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#1054](https://github.com/Verjson/.github/issues/1054)
- **Supersedes:** [ADR 0129](../0129-bridge-explicit-review-label-deliveries/README.md)
- **Extends:** [ADR 0091](../0091-ruleset-requires-authorization-arm/README.md) and [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)

## Context

ADR 0129 selected `issues:labeled` as an independent bridge for pull-request labels.
The controlled post-merge canary disproved that premise: applying `ai-review` to held,
green PR #1050 produced no workflow run. The organization-required `gate-rearm.yml`
likewise does not independently rerun for its later `pull_request_target:labeled` event.

GitHub does schedule a separate repository workflow for `pull_request_target:labeled`.
Putting that trigger on another protected caller can restore the missing delivery without
changing the ruleset identity or copying authorization policy.

## Decision

The ruleset-owned `gate-rearm.yml` caller remains label-free. A distinct protected
`ai-review-label-rearm.yml` listens only for `pull_request_target:labeled` and calls the
same immutable canonical reusable arm. Generated adopters create both callers at one
contract SHA; neither checks out PR code, executes PR prose, inherits all secrets, or
contains authorization policy.

The arm accepts an explicit label only through the separate caller and binds its exact
path, protected default-branch ref, workflow revision, run and first attempt, repository
ID/name, delivery actor, event PR head, authoritative current PR head and current label,
and current maintain/admin permission. A stale head, removed label, fork, replay, malformed
identity, source mismatch, or API failure stops before paid dispatch.

Schema 1 remains exclusive to the organization-required arm. Schema 2 remains exclusive
to the separate label caller. Receipt verification resolves the caller file at the
receipt's workflow commit and at the protected default branch and requires the exact Git
blob identities to match. Thus a merely well-formed or substituted 40-hex workflow SHA
cannot authenticate a different caller revision, while unrelated default-branch commits
do not invalidate an unchanged protected caller.

## Consequences

- The failed `issues:labeled` trigger and its assumptions are removed.
- Authorization policy remains single-sourced in `gate-rearm.yml`.
- The new caller is a separate protected trigger, not a substitute organization-required
  workflow and not a terminal merge authority.
- Rollout requires independent exact-head review, green CI, and another held live canary.
  No affected hold may be removed until that canary records the label caller, receipt,
  exact-head review, and isolated merge-App continuation.
