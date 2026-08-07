# 0074 — Privileged merge trusts signed gate provenance

- **Date:** 2026-08-07
- **Issue:** [#261](https://github.com/Verjson/.github/issues/261)
- **Supersedes:** ADR 0039's ambient-ruleset configuration as the authorization anchor
- **Extends:** ADR 0044's entry-workflow binding and the #279 decision to reject repository-authored reusable callers
- **Category:** Merge authorization / artifact provenance
- **Status:** Accepted

## Context

The gate writes a run- and head-bound `attestation.json`, uploads it as
`merge-attestation-<run-id>`, and the privileged workflow validates its fields
before using an organization administration token to merge.

ADR 0039 admitted organization-required workflow runs by rereading the current
ruleset configuration. ADR 0044 additionally required the gate to be the run's
entry workflow. Those checks reject the known reusable-call and repository-local
forgeries, but the artifact itself remained unsigned. A repository administrator
could briefly install an impostor required workflow at the canonical path, let it
upload a hand-written payload, remove that configuration, and race the later
ruleset reads.

The producing workflow identity must be evidence about the workflow that
actually signed the payload, not an inference from configuration observed later.

## Decision

The gate signs the exact uploaded `attestation.json` with
`actions/attest-build-provenance` at an immutable action commit. Its job receives
only the additional permissions that signing requires:

- `id-token: write`
- `attestations: write`

Before parsing or trusting the payload, the privileged merger extracts it to a
file and runs:

```text
gh attestation verify <payload> \
  --repo <consumer repository> \
  --signer-workflow Verjson/.github/.github/workflows/ai-review-merge.yml
```

Any missing attestation, digest mismatch, signature failure, wrong signer, or
verification-tool failure is fail-closed. JSON field validation, exact-head
binding, entry-workflow checks, and the repeated pre-merge revalidation remain
in force.

Ruleset and run-shape checks remain useful for candidate discovery and denial-
of-service resistance, but they no longer authorize artifact contents. The
GitHub-signed provenance is the authorization anchor for organization-required
and `.github`-local direct workflow shapes. Repository-authored reusable callers
remain review-only under #279; this change does not silently restore a privileged
path that the current contract explicitly rejects. No organization ruleset or
policy is changed.

## Consequences

- A consumer-repository administrator cannot mint a trusted merge attestation
  by copying the workflow path, check name, artifact name, or JSON schema.
- Repository-authored reusable callers remain unable to request privileged
  merge. Restoring that authority would require its own end-to-end contract.
- Verification has a GitHub attestation-service availability dependency. An
  outage blocks autonomous merge; it never permits an unsigned fallback.
- The gate job now holds an OIDC token-minting permission. It remains isolated
  from `ORG_ADMIN_TOKEN`; only the separate privileged workflow holds merge
  authority.
- Tests execute the shipped privileged script against valid, unsigned,
  wrongly-signed, and missing-tool cases, and pin the signing permissions,
  subject path, action count, and canonical signer workflow.
