---
date: 2026-08-18
issue: 699
title: Add the observe-first Renovate compatibility control plane
impact: minor
---

Add a least-privilege compatibility reconciler, stack-scoped failure fingerprinting,
secretless candidate canaries, and an immutable generated consumer caller. The initial
rollout reports evidence without automatically creating or mutating compatibility
holds.

**2026-08-20 update:** the dedicated compatibility App's credentials
(`RENOVATE_COMPATIBILITY_CLIENT_ID` / `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY`) were
never provisioned, so both workflows were non-functional since this landed. Per
[ADR 0111](../docs/decisions/0111-interim-pat-for-renovate-compatibility-control-plane/README.md),
both now authenticate with a single `RENOVATE_COMPATIBILITY_PAT` secret as a deliberate,
time-boxed substitute until the dedicated App is provisioned.
