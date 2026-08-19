---
date: 2026-08-19
issue: 932
impact: patch
title: secretless-rebuild-packages now asserts the lock's full install-script surface
---

`node-ci.yml`'s `secretless-rebuild-packages` input let a consumer name packages to rebuild in the credentialless job, but the workflow only verified those names appear in the lockfile — not that they are the complete set of packages the lock actually marks as needing install-time code execution (npm's `hasInstallScript`, pnpm's `requiresBuild`). A dependency update that silently added a lifecycle script to some other, unnamed package passed review unnoticed, and a stale name left in the allowlist looked like continued intent rather than drift. The step now fails closed on either direction of mismatch: a lock-declared install-script package missing from the allowlist, or an allowlisted name the lock no longer marks as needing one — turning the input into the reviewed assertion consumers already assumed it was.
