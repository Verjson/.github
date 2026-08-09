---
date: 2026-08-08
issue: 657
title: Preserve canonical review policy across dispatch
impact: patch
---

Carry the exact six-field AI review policy across Actions outputs, receipts,
and `workflow_dispatch` as a strictly validated base64url envelope. Trusted
consumers reject malformed or non-canonical encodings before provider, model,
budget, actor permission, or pricing policy can be used.
