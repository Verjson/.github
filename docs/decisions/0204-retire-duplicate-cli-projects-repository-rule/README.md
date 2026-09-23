# 0204 — Retire duplicate cli-projects repository rule

- **Date:** 2026-09-23
- **Status:** Accepted
- **Issue:** [#1576](https://github.com/Verjson/.github/issues/1576)
- **Supersedes in part:** [ADR 0153](../0153-cli-projects-package-surface-required-workflow/README.md)
- **Category:** ruleset enforcement

## Context

ADR 0153 planned to activate repository ruleset `21567958` alongside the organization
required-workflow rule. [verjson-cli-projects#117](https://github.com/Verjson/verjson-cli-projects/issues/117)
later recorded why the repository rule was disabled on 2026-09-02: its standalone
`package-surface-contract` status became obsolete after package-surface verification moved
inside protected organization-required CI.

The merged rehearsal for [#1423](https://github.com/Verjson/.github/issues/1423) correctly
failed when the repository rule no longer matched ADR 0153's `evaluate` preimage. The live
organization rule is also intentionally disabled at reviewed workflow revision
`4525c152a77bd04c006fa2b790f4b64833b1bbbe`; a safe rotation must recognize and preserve
that exact image rather than treating any disabled rule as equivalent.

## Decision

Repository ruleset `21567958` remains disabled at its exact reviewed image and is not part
of the activation transaction. The organization required-workflow ruleset is the sole
package-surface enforcement boundary.

The rollout recognizes both the prior active organization image and the exact live prior
disabled image. Dry-run validates a present rule against those reviewed preimages. Apply
may rotate either reviewed preimage to the new active workflow, and a failed or ambiguous
rotation restores the exact preimage it observed. Any other live image fails closed.

Activation still requires explicit human acknowledgement. A fresh exact-head
required-workflow canary and live readback must succeed after activation.

## Consequences

- The obsolete repository check cannot deadlock pull requests after the protected workflow
  has already performed the same package-surface verification.
- A disabled organization rule is not accepted merely because its enforcement field is
  disabled; workflow identity and the complete mutable image remain exact.
- Retrying an interrupted rotation preserves the reviewed state that existed before the
  transaction.
- ADR 0153 remains the record of the original design; this ADR records and links the
  subsequent partial supersession.
