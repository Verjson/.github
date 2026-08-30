---
date: 2026-08-30
issue: 1163
impact: patch
title: Exercise runner canary signal cleanup behavior
---

Exercise the runner canary admission script's real signal and cleanup functions with
isolated mocks, covering INT and TERM status preservation, cleanup-query failures, and
the absence of surviving owned disposable resources. Exact Docker argument and target
checks also prove that sibling, network, or image cleanup cannot silently target a
different resource.
