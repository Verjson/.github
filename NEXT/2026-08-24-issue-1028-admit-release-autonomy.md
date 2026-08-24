---
date: 2026-08-24
issue: 1028
impact: patch
title: Admit least-privilege release proposal callers
---

Generated release proposal callers now select separate reusable entrypoints for issue proposals and Release dispatches, so GitHub can admit each call graph without granting the other mode's write authority.

ADR 0122 preserves source-fixed autonomy, immutable contract pins, and symmetric execution while binding each caller to exactly one reusable workflow and write permission.
