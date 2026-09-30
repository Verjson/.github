---
date: 2026-09-30
id: 9c31a7e2
impact: patch
title: Validate AI review lifecycle caller receipts
---
Lifecycle re-arm receipts now bind to the exact protected lifecycle workflow, permitted action, source run, repository, and actor; receipt verification and orphan recovery enforce the same provenance. See [Verjson/.github#1663](https://github.com/Verjson/.github/issues/1663).
