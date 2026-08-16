---
date: 2026-08-16
issue: 850
impact: patch
title: Preserve AI review across synchronize cancellation
---

AI review reservations are now capped per exact head, so a canceled stale-head run cannot exhaust review eligibility for a replacement revision.

The gate rechecks authoritative head state before both provider reservations and durably publishes explicit supersession diagnostics or validator-confirmed stale-head verdicts without granting current-head authority.
