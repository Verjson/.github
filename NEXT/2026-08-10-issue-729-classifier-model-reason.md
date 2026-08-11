---
date: 2026-08-10
issue: 729
title: Keep AI review classification executable
---

Remove a stale model-variable reference that stopped ordinary code pull requests before AI review, and make the extracted classifier contract fail on any non-zero execution.

The selected model remains available through its validated step output; the lane reason no longer duplicates that policy value.
