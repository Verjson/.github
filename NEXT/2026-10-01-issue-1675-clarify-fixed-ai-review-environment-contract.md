---
date: 2026-10-01
issue: 1675
impact: patch
title: Clarify fixed AI review environment contract
---

Clarify that ADR 0166 assigns generated gate callers to the `ai-review-app` role environment. The reusable input is part of the workflow-call contract; the generated-caller contract test pins this caller's value, while runtime policy validates the supplied environment's `main` branch policy. See [ADR 0166](../docs/decisions/0166-environment-only-app-private-keys/README.md) and [Verjson/.github#1675](https://github.com/Verjson/.github/issues/1675).
