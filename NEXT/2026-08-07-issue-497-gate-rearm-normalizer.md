---
date: 2026-08-07
issue: 497
title: Re-arm the gate after every normalized hold spelling
---

Re-arm the merge gate when any hold label recognized by its separator normalizer is removed, while denying the gate's own `re-review` cleanup event.

The `unlabeled` guard now uses a `re-review` denylist instead of a finite hold-spelling allowlist. The trusted step applies the same hold normalizer before any API read or gate dispatch, so unrelated label churn stays cheap. ADR 0063 records the re-entrancy constraint.
