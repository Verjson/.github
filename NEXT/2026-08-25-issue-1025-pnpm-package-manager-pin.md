---
date: 2026-08-25
issue: 1025
impact: patch
title: Accept integrity-qualified pnpm updates from Renovate
---

Accept Renovate's package-manager update rows when pnpm's previous version is an exact SHA-512-qualified Corepack pin, while rejecting malformed pins and equivalent long values for other packages.
