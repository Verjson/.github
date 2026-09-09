---
date: 2026-09-09
issue: 1278
impact: patch
title: Stop cancelled DeepSeek reviews before fallback spending
---

Cancelled reviews no longer reserve or invoke a DeepSeek fallback. Both provider
passes verify the current PR head immediately before invocation and stop after five
minutes, preserving the existing exact-head pass cap and verdict authorization.

Regression tests cover cancellation, legitimate fallback, stale heads, failed
GitHub lookups, and the provider credential boundary. Existing immutable callers
must adopt the corrected canonical revision to receive these protections.
