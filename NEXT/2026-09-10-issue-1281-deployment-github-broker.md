---
date: 2026-09-10
issue: 1281
impact: minor
title: Add a credential-separated deployment GitHub broker
---

Generate a parent-owned manifest and canary broker with dedicated single-repository App authority, complete transaction request binding, exact attested manifest bytes, durable dispatch intent and authenticated runner/run/job/artifact receipts. Mocked adversarial tests cover credential isolation, stale or mismatched evidence, ambiguous dispatch and artifact tampering. This is partial capability: CLI-cloud #504 owns the missing read-only host export, and controller integration, protected issuer provisioning and live deployment/rollback acceptance remain required under ADR 0170.
