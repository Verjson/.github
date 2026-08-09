---
date: 2026-08-08
issue: 664
title: Bind review policy into terminal promotion
impact: patch
---

Carry the exact opaque review-policy envelope through immediate terminal
promotion, deterministic-CI retry, hold-removal recovery, and generated reusable
callers. The terminal verifier binds it to the immutable arm receipt and exact
head before any merge-readiness decision, without dispatching another paid review.
