# 0143 — Populate secretless runtime cache from public lock blobs

- **Status:** Accepted
- **Date:** 2026-08-26
- **Supersedes:** none
- **Category:** Security-sensitive (credentialless package-cache boundary)
- **Issue:** [#1109](https://github.com/Verjson/.github/issues/1109)

## Context

The canonical secretless npm lane installs the exact lock graph from a bounded
private cache while public registry access remains available. It then destroys
that install cache and exports a separate empty runtime cache to PR-authored
scripts. This prevents credentials and request metadata from crossing the
boundary, but it also prevents an offline release rehearsal from reinstalling
the exact graph.

Repacking `node_modules` is not equivalent to preserving registry bytes. npm
versions and package include rules can produce a tarball whose SHA-512 differs
from the immutable lock integrity; `yocto-queue@0.1.0` is a concrete example.
Fetching again inside repository-authored code would weaken the offline proof.

## Decision

Add a default-off `secretless-runtime-public-cache` input to canonical
`node-ci.yml`. For npm only, the credentialless install step may opt in after
its exact `npm ci` has completed. The canonical step enumerates only HTTPS
`registry.npmjs.org` tarballs from the exact package lock, requires canonical
SHA-512 integrity, and verifies the corresponding content-addressed source blob
before copying it.

The destination is bound to the current run and attempt's literal runner-temp
runtime-cache path and must not already exist. The copy creates only
`_cacache/content-v2/sha512` files: never an npm cache index, URL or request
metadata, symlink, private-registry blob, `@verjson` package, or credential.
Internal scopes are rejected even if a changed lock points them at the public
host. A digest that is also identified as private fails closed.

The handoff is capped at 4,096 unique blobs and 256 MiB. Missing, non-regular,
corrupt, over-count, over-size, private-package, destination, and unexpected
content states fail before repository-authored scripts run. The normal
job-scoped runtime-cache cleanup remains mandatory. pnpm callers cannot enable
this npm content-addressed-cache contract.

## Consequences

- Offline release rehearsals can consume the same immutable public bytes that
  completed the canonical credentialless install.
- The runtime cache is larger only for callers that explicitly opt in, with a
  fixed upper bound and no persistence beyond the job.
- Public package bytes cross into PR-authored execution, but secrets, private
  package bytes, npm request metadata, and registry authority do not.
- A lock graph exceeding either bound must reduce its rehearsal scope or adopt
  a separately reviewed contract rather than silently widening this boundary.
