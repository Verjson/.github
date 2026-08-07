# 0077 — Restore private-repository gates without speculative signing

- **Date:** 2026-08-07
- **Issue:** [#602](https://github.com/Verjson/.github/issues/602)
- **Supersedes:** ADR 0074
- **Preserves:** ADR 0044 and #279's non-authoritative reusable callers
- **Category:** Merge authorization / artifact provenance
- **Status:** Accepted

## Context

ADR 0074 added GitHub artifact attestations to close #261. GitHub does not make
that feature available to Verjson's private repositories on the current plan,
so every otherwise-approved consumer gate failed before privileged merge.

A keyless Sigstore replacement was evaluated. Its certificate claims for a
required workflow executing in a private consumer were not proven to bind the
canonical workflow rather than the consumer execution. Shipping an unverified
claim mapping would preserve the outage while adding another security boundary.
Changing billing, visibility, secrets, or organization policy is outside this
workflow change.

## Decision

Revert ADR 0074's attestation permission, signing action, and privileged
signature verification. Continue to accept only the run-bound JSON artifact
from a gate run authenticated by the existing conjunctive controls:

- organization-required-workflow source and exact canonical entry path;
- repository, event, workflow, run ID, PR number, and expected head SHA;
- newest trusted run selection;
- workflow-file human hold; and
- immediate pre-merge ruleset, head, and required-check revalidation.

Repository-authored reusable callers remain review-only under #279. This
restoration does not claim that unsigned artifacts solve #261; it restores the
last deployable fail-closed boundary while signed provenance remains tracked as
open work.

## Consequences

- Private consumers no longer require an unavailable GitHub plan feature.
- The fleet can resume autonomous merge through organization-required workflow
  runs.
- #261 remains an explicit residual risk and must be solved only with evidence
  from the actual private required-workflow identity shape.
- A future signing design needs a captured private-consumer credential/bundle
  test proving its exact verifier predicates before rollout.
