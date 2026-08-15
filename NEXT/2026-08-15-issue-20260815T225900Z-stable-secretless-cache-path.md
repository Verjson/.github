---
date: 2026-08-15
id: 20260815T225900Z
refs: 824
impact: patch
title: Stabilize the secretless cache path across runners
---

Secretless Node handoffs now use the same stable relative cache path on acquisition
and build runners, preventing runner-specific work roots from changing the cache
version and causing an exact-key restore miss.
