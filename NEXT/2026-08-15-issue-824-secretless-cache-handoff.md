---
date: 2026-08-15
issue: 824
impact: patch
title: Move secretless Node handoff off artifact storage
---

The canonical Node workflow now saves and restores its bounded private-package
handoff through an exact run-attempt Actions cache key, eliminating transfer
artifacts and the caller-level `actions: write` permission. Empty private-package
sets produce a validated empty handoff without a tokened npm request, while
non-empty locks retain exact allowlist, URL, integrity, and payload validation.
