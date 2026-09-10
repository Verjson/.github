---
date: 2026-09-10
id: 20260910T033000Z
impact: patch
title: Retire the verified App-key bootstrap during self-adoption
---

Retire both temporary bootstrap workflows and their migration-only executable, dependency, configuration and test surfaces after all three environment App proofs succeeded. Preserve ADR 0169 and immutable receipt/source pointers. Record fulfilled canonical provisioning and the protective shared-workflow freeze; broader secret copies and the shared pin remain unchanged pending the complete #1285 cohort rollout.
