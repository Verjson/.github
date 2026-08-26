---
date: 2026-08-26
id: 20260826T224500Z
impact: patch
title: Bind zero-provider recovery to the dispatched head
---

Pass the immutable dispatched head into zero-provider recovery so the verifier can
authenticate its receipt before any provider boundary is crossed.

This corrects the post-merge integration defect tracked by #1112 and adds a mutation
test that rejects workflows which omit the exact-head binding.
