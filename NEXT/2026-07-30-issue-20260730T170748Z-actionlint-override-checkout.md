---
date: 2026-07-30
id: 20260730T170748Z
title: Skip the central actionlint checkout for caller overrides
---

Reusable callers that provide `config-file` no longer pay for a redundant checkout of
the default central policy.

Closes #214.
