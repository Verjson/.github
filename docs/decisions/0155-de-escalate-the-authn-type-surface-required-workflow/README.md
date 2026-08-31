# 0155 — De-escalate the authn type-surface required workflow until its consumer prerequisites land

- **Date:** 2026-08-31
- **Status:** Accepted
- **Issue:** [#1215](https://github.com/Verjson/.github/issues/1215)

## Context

Organization ruleset `21750617` (`authn-type-surface-required-workflow`) required
`.github/workflows/authn-type-surface-required.yml` at its reviewed immutable SHA
`f2f425e9` on `Verjson/verjson-authn` `~DEFAULT_BRANCH`, with no bypass actors, following
the pattern ADR 0153 established for `verjson-cli-projects`.

The workflow passes `secretless-auxiliary-source` naming
`.github/ci/type-surface-base.json`, and a compatibility range whose script is
`test:type-surface-compatibility`. Neither artifact exists on `verjson-authn` `main`. Both
are introduced only by `Verjson/verjson-authn#251`, a draft explicitly marked
`DO NOT MERGE` pending independent review. The required workflow was therefore armed
against a consumer state that had not shipped.

A required-workflow rule contributes required checks, so every run failing at
`Resolve immutable auxiliary source` made every pull request in `verjson-authn`
unmergeable — including the pull requests that would land the prerequisites, and including
two unrelated pull requests repairing a separate broken required check. With
`bypass_actors: []` and `current_user_can_bypass: never`, no administrator merge could
clear it. The deadlock was not resolvable from the consumer repository.

ADR 0153 already records the intended handling for this state: the equivalent
`verjson-cli-projects` ruleset sits in `evaluate` precisely "because no producer exists on
`main`". That precedent was not applied here.

## Decision

Move ruleset `21750617` from `active` to `evaluate` until `verjson-authn` `main` carries
the prerequisites the pinned workflow reads. Change nothing else: the workflow pin, the
repository condition, the ref condition and the empty bypass list are unchanged and were
verified byte-identical after the change.

`evaluate` keeps the workflow running and reporting on every pull request, so the evidence
the rule exists to produce is still collected and still visible; it simply stops gating
merges while it cannot succeed. Disabling the ruleset, or repointing it at a workflow
edited to skip the auxiliary source, were both rejected: the first stops producing evidence
altogether, and the second converts a genuine verification into a required check that
passes without verifying anything.

Re-activation is gated on the checklist in #1215 — the two artifacts present on `main`, one
green `Authn required type surface` run on a real pull request head, and a confirmation
that a follow-up pull request is still mergeable afterwards.

## Consequences

`verjson-authn` pull requests are mergeable again on their other required checks. Between
now and re-activation, type-surface verification for `verjson-authn` is advisory: a
regression it would have caught can merge. That window is the cost of having armed the rule
before the consumer could satisfy it, and #1215 is the control that closes it.

The wider rule this records: an organization-owned required workflow must not be set
`active` until the consumer artifacts it reads are present on the consumer's default
branch. Arming it earlier does not enforce the contract, it removes the repository's
ability to adopt the contract at all. New required workflows start in `evaluate` and are
promoted on evidence, per ADR 0153.
