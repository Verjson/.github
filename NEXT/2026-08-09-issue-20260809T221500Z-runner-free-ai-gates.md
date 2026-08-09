---
date: 2026-08-09
id: 20260809T221500Z
title: Make runner-free AI gate waiting a structural contract
---

Prohibit both AI review and privileged merge jobs from polling or sleeping while external CI is pending, and generate the consumer completion bridge that re-enters exact-head terminal promotion for #341.

Record the runner-independent invariant in ADR 0087 and cover polling-loop mutations in the merge-gate contract suite.
