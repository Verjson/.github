---
date: 2026-08-09
issue: 265
title: Audit organization Actions secret scope before mutation
---

Record every organization Actions secret's justified consumer boundary and run a trusted read-only schedule that fails closed when live visibility or selected-repository grants drift from that reviewed policy (ADR 0088).

The audit is read-only and mocked in tests; live organization secret settings still require separate exact-head approval and semantic consumer verification.
