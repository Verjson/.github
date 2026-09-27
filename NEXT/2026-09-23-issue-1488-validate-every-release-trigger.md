---
date: 2026-09-23
issue: 1488
title: Validate every discovered release workflow trigger
impact: patch
---

Remove the last-caller-only trigger assertion from the emitted changelog contract and
cover a multi-release adopter whose non-final workflow is incorrectly push-triggered.
Raise the bounded actions-CI worker ceiling after the expanded changelog-release group
completed all 62 commands but was canceled during finalization at the former limit.
