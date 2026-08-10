---
date: 2026-08-09
issue: 696
title: Require immutable pins for every active GitHub Action
---

Pin every active remote Action reference to a reviewed commit and enforce the invariant repository-wide with semantic YAML and mutation tests.

Local `./` references remain allowed because they resolve from the already-reviewed checkout. Remote first-party `Verjson/.github` references receive the same immutable-SHA treatment as third-party Actions, avoiding a privileged exception that could silently widen later.
