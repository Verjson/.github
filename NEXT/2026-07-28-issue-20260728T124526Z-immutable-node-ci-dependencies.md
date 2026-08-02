---
date: 2026-07-28
id: 20260728T124526Z
title: Make node-ci dependencies transitively immutable
---

Pin the co-located CI-eligibility action to the reviewed commit that introduced
it, remove its mutable-ref Renovate exception, and make policy tests walk the
live dependency graph. Document `v2.1.0` as the exact repo-wide SemVer release
for shared actions and reusable workflows, with `v2` retained as the explicitly
moving major option. See #162 and ADRs 0014/0023.
