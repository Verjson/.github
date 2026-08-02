---
date: 2026-07-30
id: 20260730T175623Z
title: Harden runner-lane migration seams
---

Merge-gate preflight now stays on the untrusted lane until target visibility is
resolved, and admission reconciliation accepts both compatibility and namespaced lane
labels.

Closes #225 and #226. Refs ADR 0035.
