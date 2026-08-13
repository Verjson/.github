---
date: 2026-08-13
issue: 772
title: Fail privileged merge pin tests closed when their workflow step changes
---

The privileged merge pin test now structurally locates the current terminal merge step, rejects missing or empty scripts, and runs in the merge-gate CI group.

Mutation coverage prevents another workflow step rename from silently disabling the pin assertions.
