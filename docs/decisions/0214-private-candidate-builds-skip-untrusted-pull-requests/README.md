# 0214 — Keep private package contents out of pull-request candidate builds

- **Date:** 2026-10-02
- **Status:** Accepted
- **Issue:** [#1679](https://github.com/Verjson/.github/issues/1679)
- **Category:** CI authority and package publication (sensitive class)
- **Supersedes in part:** [ADR 0078](../0078-container-release-and-runner-deployment-contract/README.md)'s #690 permission to transfer acquired private packages into pull-request-controlled Docker builds and [ADR 0124](../0124-split-container-candidate-authority-entrypoints/README.md)'s inclusion of private-package acquisition in the pull-request entrypoint

## Context

The read-only container-candidate entrypoint acquired private Node packages for
same-repository pull requests. It withheld registry credentials from Docker, but
the resulting `node_modules` tree was still mounted into PR-controlled Dockerfiles
as the `verjson_node_modules` BuildKit context. A Dockerfile could copy and exfiltrate
those package sources without receiving the acquisition token.

## Decision

The pull-request entrypoint never acquires private packages. It does not declare
`NODE_AUTH_TOKEN`, accept an acquisition implementation digest, or contain a
private dependency cache restore. When `privateNodePackages` is non-empty, it
reports that candidate Docker builds were skipped and does not run any PR-controlled
Dockerfile. The prepare job reads and validates candidate metadata only.

For public-only configurations, pull-request builds remain credential-free and
receive only an empty `verjson_node_modules` context. The trusted publication
entrypoint remains the only path that may acquire private packages. It uses the
reviewed lockfile and exact package allowlist, disables lifecycle execution, and
builds only source admitted from the protected default branch.

## Consequences

- A PR that configures private packages has a successful, explicit skip status for
  candidate Docker builds; the protected-branch publication builds the candidate
  after merge.
- Adding a private package no longer needs a separate PR solely to pre-approve its
  allowlist. The untrusted validation path never receives package credentials or
  package bytes, even when the PR changes the allowlist.
- The #690 integrity, exact-scope, lifecycle, cache, and cleanup controls continue
  to govern trusted publication acquisition. This decision supersedes only the
  former transfer of the resulting package contents into PR-controlled builds.

## Verification

The generated private-package caller contract asserts that validation has only
`actions: read` and `contents: read`, forwards no secret, and leaves package-token
forwarding on trusted publication. The reusable-workflow contract asserts that a
private-package PR skips its Docker job and that the read-only graph contains no
acquisition or cache-restore route. `scripts/container_private_dependencies.test.py`
preserves exact registry and integrity rejection for ordinary lock entries.
