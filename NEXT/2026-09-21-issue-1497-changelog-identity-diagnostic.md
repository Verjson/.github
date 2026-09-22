---
date: 2026-09-21
issue: 1497
impact: patch
title: Explain issue-less changelog identity diagnostics
---

When an issue-less timestamp or hexadecimal identity is mistakenly placed in `issue:`, validation now directs the author to the `id:` key while preserving the filename contract.
