---
date: 2026-09-23
issue: 1363
impact: patch
title: Separate AI authorization enrollment from core checks
---

Give the AI authorization arm its own organization-controlled repository property and
add audited, cohort-preserving migration and rollback payloads so adopting deterministic
core checks no longer silently changes AI review enforcement.
