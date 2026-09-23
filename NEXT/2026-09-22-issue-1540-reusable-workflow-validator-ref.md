---
date: 2026-09-22
issue: 1540
impact: patch
title: Complete the Actions-owned authorization contract
---
Use the pinned App-key environment policy result for re-arm validation and
require GitHub Actions App `15368` to own every authorization receipt, check,
terminalizer, recovery, promotion, and post-merge evidence path. This avoids a
checkout at a caller workflow SHA that may not exist in `Verjson/.github`,
prevents review dispatch when the policy check fails, and removes
`checks:write` from the dedicated review App while retaining its identity for
approval-author verification
([ADR 0203](../docs/decisions/0203-retire-review-app-authorization-check-ownership/README.md)).

Part of #1540
