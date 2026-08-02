---
date: 2026-07-30
id: 20260730T174545Z
title: Make runner lanes variable-driven for new repositories
---

Reusable workflows now select independent organization variables for private/default
and public-or-unresolved workloads. Both variables intentionally target the shared
`general` fleet during the temporary permissive exception, while runner admission and
capacity reconciliation validates the live organization policy.

Closes #223. Refs #201, #203, #204, ADR 0035.
