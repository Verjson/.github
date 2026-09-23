---
date: 2026-09-23
id: 20260923T000011Z
title: Allow protected scripts without an optional runtime cache
impact: patch
---

The protected candidate-script sandbox now treats an absent npm runtime cache
as the intentional default when public cache population is disabled. Existing
cache paths remain strictly validated, snapshotted, and isolated; the change
prevents the protected baseline lane from failing before it can run a valid
credentialless consumer script plan.
