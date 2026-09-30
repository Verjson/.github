---
date: 2026-09-30
issue: 1660
impact: patch
title: Normalize gen-adr-index exit status
---
The `gen-adr-index` package command now returns 1 for unexpected child exits while preserving exit 2 for invalid arguments.
