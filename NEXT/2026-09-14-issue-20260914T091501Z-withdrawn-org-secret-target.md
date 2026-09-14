---
date: 2026-09-14
id: 20260914T091501Z
title: Declare broad App key copies withdrawn
impact: patch
---

Part [#1285](https://github.com/Verjson/.github/issues/1285).

`config/org-actions-secret-policy.json` now declares the broad organization
copies of the five tracked App private keys as withdrawn. The scope audit
accepts an absent withdrawn copy and fails with the surviving key when a broad
copy remains. This makes the policy track the real migration state without
claiming that operator-side secret deletion has already occurred.
