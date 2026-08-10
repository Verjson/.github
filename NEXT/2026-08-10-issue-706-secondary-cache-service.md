---
date: 2026-08-10
issue: 706
title: Support a secondary Redis-compatible CI service
---

Let Node CI callers opt into a Redis-compatible cache container alongside the existing Postgres service, with an isolated dynamic loopback port, environment placeholder substitution, readiness checking, and always-run teardown.
