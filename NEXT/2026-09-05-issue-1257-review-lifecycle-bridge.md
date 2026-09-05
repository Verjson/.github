---
date: 2026-09-05
issue: 1257
impact: patch
title: Bridge draft and hold review lifecycle events
---

Extend the separate generated review caller to deliver ready-for-review, draft,
hold-removal and title-edit events that required workflows cannot dispatch. Preserve
exact-head source authentication and existing authorization policy. Explain the
installation requirement when an arm stops on draft or hold.
