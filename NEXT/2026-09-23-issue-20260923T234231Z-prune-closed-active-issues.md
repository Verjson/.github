---
date: 2026-09-23
id: 20260923T234231Z
impact: patch
title: Prune closed issues from the Active Issues index
---

Removed the #1502 and #1565 entries from `CLAUDE.md`'s Active Issues index; both
issues are closed. Stale entries there cost context in every session and
misreport work as open, per the index's own pruning rule.
