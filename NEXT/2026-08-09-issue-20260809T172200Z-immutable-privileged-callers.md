---
date: 2026-08-09
id: 20260809T172200Z
title: Pin generated privileged callers to immutable contract revisions
---

Requires an immutable canonical contract SHA when generating privileged merge callers
and records the same SHA in each caller's reproducible regeneration command
(Verjson/.github#676; ADR 0085).
