---
date: 2026-08-25
issue: 1061
impact: patch
title: Bind privileged callers to exact terminal verification reads
---

Generate primary and retry terminal-merge callers with the exact non-writing Actions,
checks, contents, and pull-request read ceiling required by the App-backed reusable
workflow, preventing zero-job startup failures without restoring PAT authority.
