---
date: 2026-08-07
issue: 378
refs: 390
impact: minor
title: Enforce changelog release impact centrally
---

Add canonical `major`, `minor`, and `patch` impact metadata and require the exact corresponding SemVer bump before a selected release can mutate snapshots or fragments.

ADR 0067 defines ordinary `0.x` semantics, migration-safe patch defaults, and component/subset isolation.
