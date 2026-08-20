---
date: 2026-08-20
issue: 699
impact: minor
title: Authenticate the Renovate compatibility control plane with an interim PAT
---

The reconciler and grouping-planner workflows were non-functional since #699 was
filed: their App-token minting step required `RENOVATE_COMPATIBILITY_CLIENT_ID` and
`RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY`, neither of which was ever provisioned. Per
[ADR 0111](../docs/decisions/0111-interim-pat-for-renovate-compatibility-control-plane/README.md),
both workflows now authenticate with a single `RENOVATE_COMPATIBILITY_PAT` secret
directly, as a deliberate, time-boxed substitute for ADR 0109's dedicated
least-privilege App until that App is provisioned.
