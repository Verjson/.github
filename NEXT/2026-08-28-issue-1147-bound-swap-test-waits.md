---
date: 2026-08-28
issue: 1147
impact: patch
title: Bound compatibility race synchronization by deadlines
---

Replace iteration-count waits in the swap/load/restore race fixture with monotonic
ten-second deadlines so loaded CI hosts retain the full synchronization budget.
