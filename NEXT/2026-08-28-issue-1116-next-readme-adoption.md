---
date: 2026-08-28
issue: 1116
impact: patch
title: Accept NEXT documentation during changelog adoption
---

Allow a repository to add `NEXT/README.md`, a dependency manifest, and a valid changelog fragment in the same pull request.

The pull-request policy now distinguishes the changelog store's documentation from consumable fragments for additions, deletions, and renames. Its generated contract test reproduces the one-PR adoption shape.
