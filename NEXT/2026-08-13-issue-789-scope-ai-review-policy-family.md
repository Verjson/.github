---
date: 2026-08-13
issue: 789
title: Harden AI review adoption scope and retry
---

Repository-local generated AI review callers now require the complete nine-variable primary identity and policy family to be scoped atomically, while terminal promotion retry succeeds quietly before adoption only when both App identity variables are absent and fails closed with an actionable annotation for partial or malformed identity.

ADR 0094 records the fail-closed adoption order and the value-free 2026-08-13 pre-rollout receipt for `Verjson/verjson-ai`. ADR 0081 records the retry boundary and registered behavioral coverage proves the unadopted path performs no lookup or promotion; this repository change performs no live organization mutation.
