---
date: 2026-09-04
issue: 1246
impact: minor
title: Add bounded secretless dependency and browser caches
---

Allow failed-job reruns to reuse an immutable earlier-attempt dependency transfer within the same workflow run, add opt-in lockfile-keyed persistence for verified public npm blobs, and add a default-off Playwright browser cache for credentialless secretless jobs.

The transfer retains its random exact key and run binding. Cross-run npm persistence rejects private content, metadata, symlinks, unselected digests, and corrupt blobs before npm executes; browser caching is isolated from npm and credentialed acquisition state. This resolves #1246, #1247, and #1248.

The container-deployment contract now derives the expected `@verjson/cli-cloud` version from its manifest and proves both lockfile locations match, preventing an unrelated dependency bump from leaving a stale hardcoded CI assertion.
