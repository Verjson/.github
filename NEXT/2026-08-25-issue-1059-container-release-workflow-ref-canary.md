---
date: 2026-08-25
issue: 1059
impact: patch
title: Add a fail-closed container release workflow identity canary
---

Add a fixed manual reusable-call probe that proves GitHub supplies the exact immutable
`job.workflow_ref` before deliberately rejecting malformed candidate data, without
artifact access, App-token mint, or package or release mutation.
