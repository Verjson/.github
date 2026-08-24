# 0127 — Bind container private acquisition to the reviewed package manager

- **Date:** 2026-08-24
- **Status:** Accepted

## Context

Issue [#1019](https://github.com/Verjson/.github/issues/1019) identified that the
credential-bound container-candidate acquisition lane accepted only npm lockfiles.
Canonical Node CI already supports pnpm, but duplicating an npm lockfile in a pnpm
consumer would resolve and ship a dependency graph different from the graph it tests.

The acquisition job receives a package-read credential while processing repository
content. Its package manager, lockfile, registry scopes, lifecycle behavior, and the
credential-free artifact delivered to Docker builds are therefore trust boundaries.

## Decision

The reviewed candidate configuration selects `packageManager` as exactly `npm` or
`pnpm`; omission means `npm` for compatibility. Pull requests may use private-package
acquisition only when both that value and the exact `privateNodePackages` array equal
the base revision's reviewed values.

The npm mode accepts package-lock versions 2 and 3. The pnpm mode accepts only lockfile
version 9.0 and requires `package.json#packageManager` to pin pnpm with an exact version
and SHA-512 Corepack integrity. Its YAML is size bounded and rejects aliases, anchors,
tags, duplicate keys, aliased identities, malformed peer contexts, missing integrity,
and private entries without canonical GitHub Packages tarball URLs.

Authenticated registry scopes are derived from the exact approved package names; there
is no independently widenable scope input. Both managers run inside an empty
environment with runner-owned npm configuration and lifecycle scripts disabled. The
credential stays in the acquisition step. Docker build jobs receive only `node_modules`
and the selected lockfile digest, then bind that digest to their checked-out source.

## Consequences

Pnpm consumers can use the canonical container lane without maintaining an npm lock.
Multiple lowercase private scopes are supported only when every package is in the
reviewed allowlist. A first PR that changes the package manager or allowlist cannot
self-authorize credential use; a later synchronized head is required.

Other package managers, unpinned pnpm, legacy pnpm lockfiles, project npm configuration,
lifecycle execution, and ambient registry scopes fail closed.
