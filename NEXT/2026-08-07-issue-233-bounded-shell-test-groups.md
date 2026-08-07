---
date: 2026-08-07
issue: 233
title: Bound actions CI into cohesive parallel shell-test groups
impact: patch
---

`actions-ci` now runs platform, merge-gate, and changelog/release shell
contracts in three bounded parallel legs with fail-fast disabled. Every command
within a failed leg still runs, while an unmatrixed `shell-tests` aggregate
preserves the repository's existing required-check context.
