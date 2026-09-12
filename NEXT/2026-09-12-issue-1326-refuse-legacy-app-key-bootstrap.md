---
date: 2026-09-12
issue: 1326
impact: patch
title: Refuse legacy bootstrap copies of environment-only App keys
---

The canonical adopter bootstrap now rejects the review, merge, and release App private-key names before any GitHub or generated-output mutation and returns an explicit `provisioning_required` result. Non-App organization values and roles without an environment-only custody decision retain their current contract; existing broad copies remain untouched.

The manifest example, adopter runbook, ADR 0125 amendment, and boundary-mocked tests document the exact classification and route owners to the main-only environment provisioning path.
