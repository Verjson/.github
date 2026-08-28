---
date: 2026-08-28
issue: 1146
impact: patch
title: Defend the empty compatibility backup invariant
---

Detect an unexpected entry in an initially-absent target's empty backup container,
restore the owned target absence, preserve the unexpected state for diagnosis, and fail
with a fixed message rather than a generic filesystem exception.
