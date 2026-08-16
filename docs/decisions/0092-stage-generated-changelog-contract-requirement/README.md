# 0092 — Stage the generated changelog contract requirement behind fleet conformance

- **Date:** 2026-08-10
- **Issue:** [#731](https://github.com/Verjson/.github/issues/731)
- **Extends:** [ADR 0058](../0058-github-waits-for-checks-not-the-gate/README.md), [ADR 0075](../0075-generated-artifacts-is-the-changelog-check-prefix/README.md)
- **Category:** Organization ruleset / branch protection — **sensitive class**
- **Status:** Accepted, rollout blocked on consumer conformance
- **Context-name choice superseded by:** [ADR 0106](../0106-generated-changelog-publishes-live-required-context/README.md)

## Context

The generated changelog contract has two independent enforcement surfaces.
`generated-artifacts / validate` validates fragments and protected changelog
files. The generated `scripts/changelog-contract.test.sh` verifies that the
validation caller, renderer, contract test, and dispatched release caller all
agree on one immutable contract commit. A repository can pass fragment
validation while those four generated artifacts drift.

Verjson/verjson-cli demonstrates the second surface as the standalone
`changelog-contract` job, but organization ruleset `core-checks-node`
(20515817) requires only `ci / build-test` and `ci / eligibility`.
Its redundant repository ruleset likewise requires only `ci / build-test`.
The generated conformance suite is therefore advisory.

The canonical implementation in this repository generates all four adopter
artifacts from `scripts/gen-changelog-caller.sh`. Current adopter
Verjson/verjson-ai pins its generated workflow, renderer, contract test, and
release caller to `3848bb45fb6c4a62d7415b02aeb9d7a12f1b681e`; its PR checks show
`generated-artifacts / validate`, but it does not publish a standalone
`changelog-contract` context. It is currently exempt from `core-checks-node`,
which confirms that validation and generated-contract conformance must remain
distinct contexts rather than one being treated as evidence for the other.

### Live governed set and blocker

The live `core-checks-node` conditions select `verjson-stack=node` and
`verjson-core-checks=enforced`. On 2026-08-10 those conditions selected exactly
19 repositories:

- verjson-ai-gguf, verjson-authn, verjson-browser-agent,
  verjson-cloud-storage, verjson-cli, verjson-customer-lifecycle,
  verjson-email, verjson-eslint-config, verjson-graphql-conventions,
  verjson-identity-contracts, verjson-identity-lifecycle, verjson-infra,
  verjson-leads, verjson-object-storage, verjson-observability,
  verjson-oidc-claims-middleware, verjson-payments, verjson-temporal-kit, and
  verjson-video-forge.

Recent merged-PR evidence found the literal `changelog-contract` context only
on verjson-cli and verjson-infra. The read-only central audit is stricter: it
also requires the canonical generated-artifacts caller and the universal gate.
No selected repository currently passes the complete declared contract. The
universal-gate absence is tracked by #728; its authorization-arm repair is not
part of this decision. Activating the additional context now would permanently
block most selected repositories.

## Decision

Add `changelog-contract` to the declared Node stack contract and to the planned
`core-checks-node` contexts. Keep `generated-artifacts / validate` in the
separate `changelog-contract-required` property-scoped ruleset. Neither context
replaces the other.

Replace the inert plan-only declaration with a staged, human-gated rollout:

1. Read the live ruleset by its fixed organization ID and require its target,
   enforcement, default-branch scope, property conditions, and existing
   contexts to match the declaration. Capture the complete mutable ruleset
   preimage; an unexpected difference is a conflict, not something to overwrite.
2. Enumerate repositories from the live organization property values and freeze
   the exact selected set, default branches, and head commits satisfying every
   live property condition. Audit only those commits. Exempt and unrelated
   repositories are never mutated or used to justify activation.
3. Refuse mutation unless every selected repository passes source and observed
   context conformance. The audit regenerates the workflow, renderer, contract
   test, and release caller with the canonical generator at the declared
   immutable pin and requires byte identity. It first proves that consumer pin
   is reachable from the canonical repository's current default-branch head,
   then executes the merged generator with a minimal credential-free
   environment. Handwritten lookalikes, unmerged generator code, weakened
   triggers or job semantics, unreadable APIs, stale callers, and missing checks
   all fail closed.
4. In apply mode, forbid contract, audit, and default-branch overrides. Require
   the declaration, audit, and rollout scripts to be byte-identical to their
   copies already merged on the repository's actual default branch, then require
   the operator's exact acknowledgement.
5. Immediately before mutation, re-discover the selected set and exact heads and
   compare the complete current ruleset preimage. Preserve existing integration
   IDs and every unrelated mutable field while adding only the declared context.
6. Before the PUT, retain a mode-`0600` recovery artifact under the common Git
   directory containing the exact preimage and intended postimage. After the
   update, verify the exact mutable postimage, re-check the frozen governed
   state, and compare every effective status-check parameter on every selected
   repository.

The rollout stays blocked while any selected repository is nonconformant. This
PR changes the canonical declaration and the gated rollout mechanism; it does
not update the live organization ruleset.

## Consequences

- A future generated workflow/renderer/contract-test/release-caller pin drift
  becomes merge-blocking for conformant Node repositories.
- Consumer migrations must use
  `Verjson/.github/scripts/gen-changelog-caller.sh`; handwritten equivalents do
  not satisfy the generated contract, even when they expose the same names.
- A failed post-write verification reports the protected recovery artifact. Its
  executable rollback refuses stale live state and restores only the artifact's
  exact preimage after binding itself and the contract to merged default-branch
  bytes.
- #728 can repair the authorization arm without adding or retiring any
  `core-checks-node` status context. The staged audit still requires the
  universal gate before this rollout can proceed.
- The literal check name is an interface. Renaming the consumer job requires a
  coordinated contract and ruleset migration.

## Rollback

Before activation, revert this declaration and rollout gate; live protection is
unchanged. After activation, invoke `scripts/required-checks-rollback.sh` with
the protected recovery artifact and the declaration's rollback acknowledgement.
The rollback proceeds only when its implementation and contract match merged
default-branch bytes and the live mutable ruleset exactly matches the artifact's
intended postimage; it then restores and verifies the exact preimage. Do not
bypass this recovery path by patching individual consumer rulesets.
