---
date: 2026-08-12
issue: 754
title: Transfer only verified private npm cache blobs
---

Populate exact locked private package URLs with npm's supported cache command, remove signed redirect indexes, and transfer only verified integrity-addressed blobs plus optional auxiliary content. The current Tequity payload falls from 157,265,920 bytes to 1,249,280 bytes while preserving the 80 MiB cap and credentialless build boundary.
