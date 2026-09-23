---
date: 2026-09-23
id: 20260923T000011Z
title: Allow protected scripts without an optional runtime cache
impact: patch
---

The protected candidate-script sandbox now treats an absent npm runtime cache
as an intentional empty baseline when public cache population is disabled.
Existing cache paths remain strictly validated, snapshotted, and isolated;
the missing-path regression is covered so the protected lane reaches the
credentialless consumer script plan instead of failing during baseline
inventory.
