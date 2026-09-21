# 0124 — Split container candidate authority entrypoints

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#1038](https://github.com/Verjson/.github/issues/1038)
- **Category:** CI authority and package publication (sensitive class)
- **Extends:** [ADR 0095](../0095-build-container-candidates-before-release/README.md), [ADR 0122](../0122-split-release-proposal-authority-entrypoints/README.md)

## Context

The container-candidate caller has two intentionally different authorities. A
pull request validates configuration and builds candidate content with read-only
repository authority. A trusted default-branch push publishes images, writes
attestations, and mints OIDC identity.

Both paths currently call one reusable workflow. That workflow contains
read-only validation jobs and publication jobs requesting `attestations:write`,
`packages:write`, and `id-token:write`. GitHub validates the complete reusable
call graph before evaluating job-level event conditions. The read-only caller
therefore cannot start: recent runs terminate as `startup_failure` with no jobs.

Granting publication permissions to the pull-request caller would make the
static graph admissible by destroying the least-privilege boundary. Hiding the
trigger would conceal red CI without making the contract executable.

## Decision

Canonical container candidate automation exposes two source-fixed reusable
entrypoints:

- `container-candidate.yml` contains only pull-request validation, bounded
  private-package acquisition, and credentialless candidate builds;
- `container-candidate-publish.yml` contains only trusted publication,
  attestation, SBOM, and candidate-manifest jobs.

Each entrypoint retains its own preparation and bounded acquisition stages so
GitHub can validate its complete static graph against exactly the permissions
the caller grants. No runtime input or event expression selects between read
and write authority inside an admitted reusable workflow.

The canonical generator emits both calls at one immutable contract SHA. The
pull-request job grants only its required reads (plus optional package read for
an explicitly configured private-package acquisition). The default-branch push
job alone grants attestation, package-write, and OIDC authority. Generated
contract tests bind both target paths, the shared immutable SHA, acquisition
digest, permissions, triggers, and byte provenance.

The attestation signer identity moves with the publishing code to
`Verjson/.github/.github/workflows/container-candidate-publish.yml@<sha>`.
Candidate configuration, emitted manifests, and release verification bind that
exact source-fixed identity; retaining the former validation path as a claimed
builder would make provenance disagree with the workflow that exercised write
authority.

The repository-local reusable-call canary follows the same split. Pull-request
runs exercise only the read-only entrypoint. Publication remains an explicit
controlled dispatch/default-branch path and is not made reachable from pull
requests.

## Consequences

- GitHub can admit the read-only validation graph without publication writes.
- A pull request cannot widen its authority through an input, condition, matrix,
  or event-shaped value.
- Some source-fixed preparation/acquisition workflow text is duplicated across
  the two entrypoints. This is preferred to a shared dynamically selected
  authority graph; conformance tests and the generator prevent semantic drift.
- Existing generated callers must be regenerated at one immutable post-merge
  contract SHA; hand-edited path substitutions are non-conforming.

## Verification

Static tests parse both reusable workflows and generated callers, reject cross-
authority jobs and permission widening, and mutate each target path and event
guard. A pull-request canary must create and complete read-only jobs instead of
ending at startup. A controlled publication dispatch must be admitted with the
write permissions confined to its publication graph. Both run receipts are
retained before downstream rollout.
