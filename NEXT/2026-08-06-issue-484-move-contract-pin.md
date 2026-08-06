---
date: 2026-08-06
title: Move the documented contract pin to the commit that carries release-node
issue: 484
---

`docs/changelog/migration.md` documented four generator commands under one `$PIN`, and the
pin could only run three of them. `release-node` landed with the fix for #463/#464/#465;
the pin still named `3d5f2896`, which predates it. An adopter following the guide verbatim
got three files and a loud failure on the fourth.

- The pin is now `0285998a`, the commit that closed #463/#464/#465, so every command the
  guide documents runs at the pin it documents.
- `scripts/contract-pin.test.sh` checks `release-node` alongside `workflow`, `renderer` and
  `contract-test`. The gap was invisible because the test enumerated three modes while the
  guide showed four, and neither side referred to the other. Adding the fourth mode fails
  against the old pin, which is what makes the two move together from now on.
- Repositories already migrated at an older pin need only regenerate; the embedded
  `contract_ref` moves with it. A repository that publishes **must** move to this pin
  before it can generate a release caller at all.

Adopters generating at this pin get the release engine that snapshots the dispatch commit
rather than re-reading the branch head, so a release raced by a concurrent merge fails
closed with no tag and every fragment unconsumed.
