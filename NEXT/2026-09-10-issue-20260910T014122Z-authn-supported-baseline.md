---
date: 2026-09-10
id: 20260910T014122Z
impact: patch
title: Align the Authn required workflow with its supported compatibility baseline
---

The canonical Authn type-surface workflow now requests the published 2.0.0 baseline permitted by the consumer's protected package policy, replacing the stale 1.0.3 request that failed the controlled activation trial. Strict validation and policy regression coverage retain the exact allowed baseline; ADR 0168 preserves the activation, rollback, and live-receipt gates for the corrected pin.
