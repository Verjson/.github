---
date: 2026-08-26
issue: 1112
impact: patch
title: Recover receipt-bound reviews that stop before provider execution
---

Preserve exact dispatch identity and causal preflight state when the paid review gate never
runs. Permit only same-run, same-receipt recovery after all prior attempts prove skipped
provider gates and no reservation, submission, review, stale head, or identity drift.
