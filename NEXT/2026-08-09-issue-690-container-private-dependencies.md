---
date: 2026-08-09
issue: 690
title: Acquire private container dependencies outside BuildKit
---

Acquire the exact approved private `@verjson/*` dependency graph from the reviewed lockfile without lifecycle execution, bind credential use to the immutable called-workflow revision and an allowlist already reviewed on the base branch, then expose only a lock-bound, credential-free `node_modules` tree as a named BuildKit context.
