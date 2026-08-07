---
date: 2026-08-07
issue: 431
title: Detect matrixed reusable callers before requiring canonical checks
summary: The required-check classifier now rejects matrixed reusable caller jobs because GitHub never emits their canonical unmatrixed check names.
---

The static stack classifier now detects block and flow-style
`strategy.matrix` definitions on reusable CI and changelog caller jobs and
reports the exact suffixed check shape that would leave canonical required
contexts permanently pending.

ADR 0058 now states the unmatrixed-caller invariant and requires open PR heads
to be updated after remediation but before ruleset activation. A read-only
Groups B/C re-sweep found one live consumer,
`Verjson/verjson-customer-lifecycle`, tracked in its issue #16.
