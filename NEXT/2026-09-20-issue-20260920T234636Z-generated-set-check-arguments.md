---
date: 2026-09-20
id: 20260920T234636Z
impact: patch
title: Remove unused generated-set checker argument
---

The generated changelog contract test no longer carries a dead generator-flags argument. The canonical generator contract test asserts the emitted checker omits it.
