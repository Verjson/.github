---
date: 2026-08-19
issue: 941
impact: patch
title: Scope secretless-rebuild-packages to packages actually installed on this platform
---

#932 made `secretless-rebuild-packages` require an exact match against the lock's
full declared install-script surface (npm's `hasInstallScript`, pnpm's
`requiresBuild`). A pnpm or npm lockfile records every platform variant of an
optional native dependency (e.g. `@esbuild/darwin-arm64`, `@esbuild/linux-x64`),
but `--frozen-lockfile`/`--ignore-scripts` only installs the ones this runner's
`os`/`cpu` actually match. The exact-match check would have forced the allowlist
to name a platform variant that was never installed here, and rebuilding it would
then fail.

`node-ci.yml`'s rebuild step now intersects the lock-declared install-script
surface with what's actually present under `node_modules/` after the preceding
credentialless install, before comparing against the allowlist.

Refs #941, #932.
