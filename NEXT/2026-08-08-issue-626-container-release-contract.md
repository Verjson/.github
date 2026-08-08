---
date: 2026-08-08
issue: 626
title: Define immutable container release and protected runner deployment
---

Accept ADR 0078: main publishes immutable candidates, explicit release promotes the exact attested digest set, and an independently approved environment deploys it through a canary and sequential rollout.

The decision defines the release-manifest schema, threat model, generated-caller contract, credential ownership boundary, audit receipts, rollback semantics, and the ordered #628, #627, and #629 migration.
