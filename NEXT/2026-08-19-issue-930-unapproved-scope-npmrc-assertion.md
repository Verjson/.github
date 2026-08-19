---
date: 2026-08-19
issue: 930
impact: patch
title: Assert no partial npmrc override is written on unapproved-scope rejection
---

The secretless pnpm install test only asserted the lockfile was left
unchanged when an unapproved scope is rejected. It now also asserts the mock
registry npmrc override file was never created, proving the fail-closed path
writes nothing before rejecting.
