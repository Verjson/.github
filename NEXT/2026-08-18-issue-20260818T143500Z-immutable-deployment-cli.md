---
date: 2026-08-18
id: 20260818T143500Z
impact: patch
title: Pin protected deployment CLI acquisition
---

Acquire the protected runner deployment CLI from the immutable contract checkout with
a fully validated SHA-512 npm lock, exact Node runtime, isolated job cache, and
guaranteed cleanup before or after any deployment operation. This corrects the
dispatchability gap found while completing #629 without creating a duplicate issue.
