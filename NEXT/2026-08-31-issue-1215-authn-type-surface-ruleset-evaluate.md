---
date: 2026-08-31
issue: 1215
impact: patch
title: De-escalate the authn type-surface required workflow to evaluate
---

- Move organization ruleset `21750617` (`authn-type-surface-required-workflow`) from
  `active` to `evaluate`. The pinned workflow reads
  `.github/ci/type-surface-base.json` and a `test:type-surface-compatibility` script that
  exist only on the held draft `Verjson/verjson-authn#251`, so every run failed at
  `Resolve immutable auxiliary source`. A required-workflow rule contributes required
  checks and this ruleset has no bypass actors, so that failure blocked every pull request
  in `verjson-authn` — including the ones that would have supplied the missing artifacts.
- Nothing else about the ruleset changed. The workflow pin `f2f425e9`, the repository and
  ref conditions and the empty bypass list were captured before the change and verified
  byte-identical after it. The workflow still runs and still reports on every pull request;
  it no longer gates merges.
- Re-activation is tracked in #1215 and gated on the prerequisites being present on
  `verjson-authn` `main`, one green run on a real pull request head, and a confirmation
  that a later pull request is still mergeable. ADR 0155 records the decision and the
  general rule: an organization-owned required workflow starts in `evaluate` and is
  promoted on evidence, never armed ahead of the consumer artifacts it reads.
