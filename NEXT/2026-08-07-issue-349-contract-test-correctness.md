---
date: 2026-08-07
issue: 349
refs: 437, 418
title: Make generated changelog contract tests fail closed
---

Verify the canonical generated release caller binds both its reusable-workflow ref and `contract_ref` to one pin, accepts `refs` metadata across a real release, and distinguishes an empty `NEXT/` from renderer failures.

Generated-fixture coverage now exercises renderer, download, digest, and Python failures before and after the exact disposable release path.
