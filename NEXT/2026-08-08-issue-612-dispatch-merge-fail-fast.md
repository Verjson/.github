---
date: 2026-08-08
issue: 612
title: Stop merge dispatch waits after prerequisite failure
---

- Release routed merge-dispatch runners as soon as a required prerequisite check reaches a terminal failure, while retaining its diagnostic evidence. When GitHub declares required contexts, advisory failures no longer block this postcondition; unresolved branch policy fails closed, and repositories without required checks retain the legacy all-check fallback.
