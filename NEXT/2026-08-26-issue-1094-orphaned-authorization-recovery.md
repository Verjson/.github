---
date: 2026-08-26
issue: 1094
impact: patch
title: Recover orphaned authorization checks across runs
---

Recover exact-head authorization checks only after their source arm is terminal, no active receipt-bound review owns them, and every repository, App, run, receipt, and check identity is revalidated.
