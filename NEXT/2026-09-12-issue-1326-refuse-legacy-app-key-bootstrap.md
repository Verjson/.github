---
date: 2026-09-12
issue: 1326
impact: patch
title: Refuse legacy bootstrap copies of environment-only App keys
---

The canonical adopter bootstrap now uses an exact credential map: `NODE_AUTH_TOKEN` is the supported non-App organization credential, while App private-key entries require the declared canonical role and exact `<role>_PRIVATE_KEY` name. Aliases such as `MERGE_TOKEN`, renamed private-key-like names, and unrecognized keys fail before any GitHub or generated-output mutation; review, merge and release roles retain an explicit `provisioning_required` result for their canonical credentials. Roles without an environment-only custody decision retain their exact typed organization-secret path; existing broad copies remain untouched.

The manifest example, adopter runbook, ADR 0125 amendment, and boundary-mocked tests document the exact classification and route owners to the main-only environment provisioning path. Provisioning receipts carry only the non-secret repository-relative path to that runbook.
