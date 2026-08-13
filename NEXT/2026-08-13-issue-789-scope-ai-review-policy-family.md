---
date: 2026-08-13
issue: 789
title: Require atomic AI review policy scope for local callers
---

Repository-local generated AI review callers now require the complete nine-variable primary identity and policy family to be scoped atomically, with App installation and provider/App secret visibility verified as separate prerequisites.

ADR 0094 records the fail-closed adoption order and the value-free 2026-08-13 pre-rollout receipt for `Verjson/verjson-ai`; this repository change performs no live organization mutation.
