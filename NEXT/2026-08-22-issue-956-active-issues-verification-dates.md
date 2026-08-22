---
date: 2026-08-22
issue: 956
title: "docs: refresh CLAUDE.md Active Issues with live-verified status and a verification-date convention"
---

Refreshed `CLAUDE.md`'s Active Issues section against live GitHub state (issue
comments, `gh api orgs/Verjson/actions/secrets`, the #731 rollout audit) rather than
carrying forward prose written days earlier. Removed #931/#701/#728/#157, all closed.
Added #731/#975/#983/#985/#986/#987/#994, discovered or dispatched to delivery agents
during this pass.

Addresses #956: each entry now states how/when its claim was last verified instead of
asserting external status from inspection alone, so a claim like "#933 not yet
confirmed" carries its own check-date rather than silently going stale.
