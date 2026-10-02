---
date: 2026-10-02
issue: 1682
impact: patch
title: Accept case-varied identities for same-repository PRs
---

Normalize GitHub owner and repository casing in the secretless Node CI boundary so same-repository PRs continue to acquire dependencies after the organization casing change while fork PRs remain rejected.
