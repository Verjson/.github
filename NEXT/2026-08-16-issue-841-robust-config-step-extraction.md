---
date: 2026-08-16
issue: 841
impact: patch
title: Make container config-step contract extraction fail closed
---

Make the container candidate contract test tolerate optional step keys before the config script while rejecting missing, malformed, or empty run blocks.

This keeps the canonical workflow test bound to the intended `config` step instead of accidentally extracting a later step when the workflow shape changes.
