---
date: 2026-08-16
issue: 834
impact: patch
title: Add trusted changelog attribution for Renovate updates
---

Generate a guarded Renovate caller that adds dependency release context without executing pull-request code.

Use a repository-scoped Release App token and a non-force exact-head Git Data API update only after strict live admission.
