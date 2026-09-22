---
date: 2026-09-21
issue: 1393
impact: patch
title: Keep queued AI review runs eligible for receipt validation
---

Receipt-bound AI review recovery now accepts a live workflow-dispatch run that is still queued while an environment-gated sibling waits for admission, while continuing to require the exact run identity and reject terminal or unrelated runs ([#1393](https://github.com/Verjson/.github/issues/1393)). Completion selects the Checks API token from the verified check owner so legacy App-owned checks can reach a terminal state; new checks remain Actions-owned. The temporary permission and its exact-receipt limits are recorded in [ADR 0200](../docs/decisions/0200-temporary-legacy-authorization-check-write/README.md), with removal tracked by [#1540](https://github.com/Verjson/.github/issues/1540).
