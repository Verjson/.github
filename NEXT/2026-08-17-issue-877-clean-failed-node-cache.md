---
date: 2026-08-17
issue: 877
impact: patch
title: Clean failed secretless Node cache attempts
---

Allocate every secretless private-package acquisition in a unique temporary cache and remove partial state immediately when acquisition fails, so persistent runners remain retryable without weakening fresh-cache validation.
