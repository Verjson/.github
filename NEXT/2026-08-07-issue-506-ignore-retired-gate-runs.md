---
date: 2026-08-07
issue: 506
title: Ignore retired workflow runs during gate discovery
---

Exclude skipped trusted runs from newest-verdict selection, allowing an older active gate at the same head to remain authoritative after required-workflow migration.

Active failed or cancelled gates remain fail-closed, all-skipped history still
reaches the bounded no-trusted-gate failure, and explicit dispatched source runs
never fall back to historical selection. ADR 0039 records why required-workflow
API endpoints cannot reliably identify retirement.
