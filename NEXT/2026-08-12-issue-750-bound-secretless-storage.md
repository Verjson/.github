---
date: 2026-08-12
issue: 750
title: Bound secretless Node CI transfer storage
---

Transfer only a verified npm offline cache under an 81 MiB artifact-envelope budget, bind it to the exact run attempt and lockfile, and delete it through a bounded no-checkout cleanup job without exposing credentials to consumer execution.

ADR 0095 preserves the secretless trust boundary from PR #681 while replacing full `node_modules` artifacts that exhausted consumer Actions storage. Adoption pins `node-ci.yml` to the immutable canonical commit and grants `actions: write` only so the isolated cleanup job can delete the exact artifact.
