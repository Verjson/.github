---
date: 2026-09-12
issue: 1326
impact: patch
title: Refuse legacy bootstrap copies of environment-only App keys
---

The canonical adopter bootstrap now requires a typed secret purpose and binds App private-key entries to the manifest's canonical App roles. Renamed or undeclared App-key entries fail before any GitHub or generated-output mutation; review, merge and release roles return an explicit `provisioning_required` result. Non-App organization values and roles without an environment-only custody decision retain their current contract; existing broad copies remain untouched.

The manifest example, adopter runbook, ADR 0125 amendment, and boundary-mocked tests document the exact classification and route owners to the main-only environment provisioning path. Provisioning receipts carry only the non-secret repository-relative path to that runbook.
