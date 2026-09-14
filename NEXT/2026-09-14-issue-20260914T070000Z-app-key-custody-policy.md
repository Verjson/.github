---
date: 2026-09-14
id: 20260914T070000Z
refs: 1326
impact: patch
title: Refuse approved organization custody for environment-only App keys
---

The organization secret-scope policy now declares custody for every App private key. `AI_REVIEW_APP_PRIVATE_KEY`, `MERGE_APP_PRIVATE_KEY` and `RELEASE_APP_PRIVATE_KEY` may appear only as `environment-only-migration-residue` with a recorded withdrawal contract, tracking issue and date; `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` and `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY` keep their current organization contract by declaring it explicitly; any other `_APP_PRIVATE_KEY` name fails closed as an unrecognized role before any GitHub read.

`scripts/org-secret-scope-audit.py` classifies custody from the policy document and secret names only, never from a secret value, and reports `secret-scope-policy=withdrawal-pending` with the residue names while any broad copy of an environment-only key remains. `conformant` now means no environment-only residue exists. Existing broad copies, live visibility comparisons and the audit's read-only exit status are unchanged; withdrawal remains owner work tracked by #1285. ADR 0176 records the custody decision and amends ADR 0088.
