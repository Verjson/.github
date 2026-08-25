---
date: 2026-08-25
issue: 1014
impact: patch
title: Enforce generated Renovate attribution admission
---

Generated changelog contract tests now reject removal or mutation of the
same-repository, Renovate-actor, and `renovate/` branch admission gate before the
Release App credential can reach the trusted attribution workflow.
