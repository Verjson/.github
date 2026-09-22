---
date: 2026-09-21
issue: 1527
impact: patch
title: Protect deployment admission authority
---

The reusable workflow now rejects non-default-branch calls before production jobs
start. Controller admission validates the complete review authority and rebuilds the
submitted plan from reviewed configuration and evidence before persisting a receipt.
This closes the direct-admission gap found while delivering #1527 and continues
#1451's protected runner deployment work. See ADR 0198.
