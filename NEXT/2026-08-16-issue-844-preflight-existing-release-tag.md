---
date: 2026-08-16
issue: 844
impact: patch
title: Reject existing release tags before mutation
---

Fail an exact changelog release before creating its commit or consuming fragments when the requested local tag already exists.
