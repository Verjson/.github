---
date: 2026-08-15
issue: 830
impact: patch
title: Move private container dependency handoff off artifact storage
---

Transfer credential-free private container dependencies through an exact repository cache key so organization artifact quota exhaustion cannot block candidate builds.

The cache key is unique to one workflow run attempt, has no prefix fallback, and retains the reviewed allowlist and lock-digest checks from ADR 0078.
