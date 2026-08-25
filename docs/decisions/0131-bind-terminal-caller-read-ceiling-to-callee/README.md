# 0131 — Bind the terminal caller read ceiling to the callee

- **Date:** 2026-08-25
- **Status:** Accepted
- **Issue:** [#1061](https://github.com/Verjson/.github/issues/1061)
- **Extends:** [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)

## Context

ADR 0120 split terminal promotion into read-only authorization under the repository
`GITHUB_TOKEN` and one merge operation under a repository-scoped installation token.
The reusable workflow consequently declares Actions, checks, contents, and pull-request
read permissions on its terminal job. Its generated primary caller still granted only
contents read, however. GitHub does not allow a called workflow to elevate the caller's
permission ceiling, so App-backed terminal dispatches failed during workflow
instantiation, before any job or diagnostic could run.

An older successful adopter was not evidence that the App path worked: it executed a
pre-App contract from before the reusable job declared the additional verification
reads. Falling back to that revision would restore the retired administrative PAT
boundary.

## Decision

Primary privileged-merge callers grant exactly the same non-writing repository-token
permissions already used by the canonical terminal authorization job:

- Actions read, to bind arm and source runs;
- checks read, to verify exact-head authorization and required checks;
- contents read, to resolve immutable verifier code and repository state; and
- pull requests read, to validate the target PR, head, labels, and merge eligibility.

The set is an exact ceiling, not a minimum to extend. Generated primary and retry
callers must match it byte-for-byte: missing reads fail workflow instantiation, while
additional reads or any write permission violate the capability split. Generated
contract tests derive startup compatibility from the canonical terminal job and reject
missing, extra, or writable mutations.

This repository token remains unable to merge or bypass rulesets. The dedicated merge
App token remains repository-bound, requests only contents write and pull-requests
write, and is delivered only to the final `gh pr merge --admin --squash` operation.
There is no PAT fallback and no inherited secret contract.

## Consequences

- App-backed callers can instantiate the reusable terminal workflow without granting
  write authority to authorization or parsing steps.
- A future callee permission change must update the canonical generator and its
  adversarial contract in the same immutable revision.
- Every adopter must regenerate both primary and retry callers at one immutable merged
  contract SHA; generated YAML must never be hand-edited.
- Existing held adopters remain blocked until this decision and implementation merge
  and their generated callers are rolled forward.
