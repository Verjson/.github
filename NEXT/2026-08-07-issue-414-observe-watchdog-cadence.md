---
date: 2026-08-07
issue: 414
title: Make fleet-watchdog scheduler gaps explicit
impact: minor
---

The scheduled fleet watchdog now records the interval from its preceding run
in the durable job summary and emits a warning when GitHub delays the nominal
15-minute schedule beyond 30 minutes. ADR 0072 keeps the privileged workflow
schedule-only and confines cadence inspection to a read-only job token.
