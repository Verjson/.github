---
date: 2026-08-09
issue: 682
title: Ignore scoped root projects during secretless dependency validation
---

Allow scoped `@verjson/*` root projects to use secretless Node validation by exempting only the package lock's exact root entry while preserving allowlist and canonical URL checks for every installed internal dependency.

This restores the installed-dependency invariant recorded in [ADR 0086](../docs/decisions/0086-secretless-node-pr-validation/README.md) after the consumer failure in Verjson/catalog-worker#71.
