# 0150 — Publish the exact-runner canary at an immutable ref

- **Date:** 2026-08-28
- **Status:** Accepted
- **Issue:** [#629](https://github.com/Verjson/.github/issues/629)

## Context

The runner repair controller must dispatch a canonical database-backed canary only to the runner held by its active transaction. A mutable branch or moving major tag could change the workflow after review, while a similar but independently authored workflow could produce a receipt that appears compatible without executing the reviewed admission probes.

The controller already binds promotion to an exact signed commit, exact workflow bytes, the runner's numeric GitHub identity, and a transaction-unique temporary label. The canonical repository needs to publish those exact bytes at a ref whose shape and lifecycle preserve that binding.

## Decision

Publish `.github/workflows/runner-canary.yml` byte-for-byte from the released `@verjson/cli-cloud` contract. Publish each compatible contract once at a lightweight semantic-version tag named `runner-canary-vX.Y.Z`, pointing directly to the signed canonical commit. Do not create or move a major/minor alias, annotate the tag, reuse a version, or dispatch `main`.

The controller must receive both the full 40-character commit SHA and the full semantic-version tag. Before dispatch it resolves the tag through GitHub, requires the ref object to be that exact commit, requires GitHub's commit verification to be valid, fetches the workflow at the tag, and compares its exact bytes with the released CLI contract. The tag alone is not authority and a moved tag fails the SHA comparison.

The workflow accepts only the exact runner name, numeric runner ID, transaction-unique label, nonce, immutable release manifest, release variant, and image digest. It routes on the unique label, verifies the runtime runner name, exercises PostgreSQL reachability, a disposable sibling Docker bridge, a representative image build, PowerShell, disk, and inode thresholds, and emits one digest-bound promotion receipt. Its permissions, runtime, probe resources, cleanup, and artifact retention remain bounded and pinned. Cleanup removes and then proves absence of the exact run-attempt container, bridge, and build image. Failed absence inventory, surviving resources, or INT/TERM at any point through the signal-safe finalization boundary deletes promotion evidence and returns a terminal failure only after every cleanup proof completes.

The hosted-selector policy admits the direct `${{ inputs.runner_label }}` expression only when parsing this repository's exact normalized repository-relative `.github/workflows/runner-canary.yml`, whose sole job has the exact selector list `[self-hosted, ${{ inputs.runner_label }}]` and whose only trigger is `workflow_dispatch`. Repository authority is rooted at the policy process's physical working directory; a caller-supplied scan directory cannot redefine that root. The canonical workflow and its workflow directory must resolve without symlinks, and the workflow itself must be a regular file. The input is not added to the organization-wide reviewed-expression allowlist or consumer-policy grammar. Another path, trigger, job, label, hosted selector, or expression shape remains fail closed.

Any workflow-byte change requires a new CLI release and a new `runner-canary-vX.Y.Z` tag at the reviewed signed canonical commit. Rollback selects an older still-verified full tag and its exact commit SHA; it never moves an existing tag.

## Consequences

- Operators can audit one exact workflow revision and replay its immutable identity.
- Mutable refs, annotated tag objects, unreviewed workflow copies, changed dependency pins, and widened runner selectors fail closed.
- CLI and canonical workflow publication must be coordinated; byte drift intentionally blocks deployment.
