---
date: 2026-08-07
issue: 585
title: Keep the Node CI database alive through consumer tests
impact: patch
---

The reusable Node CI workflow now tears down its optional database container
after every install, build, test, lint, and cache step. Cleanup remains
failure-safe, container-ID-scoped, and suppressed on the deferred Renovate
no-op path.
