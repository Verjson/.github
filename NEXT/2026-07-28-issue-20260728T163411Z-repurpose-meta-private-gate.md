---
date: 2026-07-28
id: 20260728T163411Z
title: Repurpose retired meta runners as private gate capacity
---

ADR 0029 reuses `gha-meta-1` and `gha-meta-2` for the private merge-gate lane
after ADR 0028 moved public `.github` execution to hosted capacity. Adding the
`gate` label raises private review capacity from four to six without changing
machines, selected/private-only GCP group access, workflow permissions, or
public routing (#171; observed queue: `Verjson/toquorum#283`).
