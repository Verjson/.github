---
date: 2026-07-28
id: 20260728T151509Z
title: Bound Node caches and codify CI security tiers
---

Reusable Node CI/release/setup now default Actions npm caching off on persistent
self-hosted runners. Opt-in caches are job-scoped and reusable workflows clear
them above a 1024 MB default upload bound. ADR 0028 separates isolated, trusted,
and fast CI routes, moves public `.github` and public-target gate execution to
fixed hosted capacity, and supersedes GCP's former all-repository/public access
posture (#166; consumer evidence: `Verjson/toquorum` run `30363686973`).
