---
date: 2026-09-23
id: 8d07a5c
impact: patch
title: Retire review-App authorization-check ownership
---
Require GitHub Actions App `15368` to own every authorization receipt, check,
terminalizer, recovery, retry, promotion, and post-merge evidence path. Remove
`checks:write` from the dedicated review App while retaining its identity for
approval-author verification. The change remains blocked until all live legacy
checks are terminal and the zero-active-receipt prerequisite in
[ADR 0203](../docs/decisions/0203-retire-review-app-authorization-check-ownership/README.md)
is proven.

Part of #1540
