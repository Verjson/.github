---
date: 2026-09-21
issue: 1526
impact: patch
title: Confine host observation temp files
---

Host observation credentials now require job-scoped temporary storage, and requests must
bind to the admitted deployment plan.

This completes the host-export lifecycle and plan-binding follow-ups in #1526 and #1527
while continuing #1451. See ADR 0198.
