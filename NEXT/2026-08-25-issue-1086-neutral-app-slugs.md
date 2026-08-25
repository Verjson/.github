---
date: 2026-08-25
issue: 1086
title: Fail AI authorization slug drift closed without stranded checks
impact: patch
---

Record the canonical CI Apps' organization-neutral live identities and make the AI
authorization arm reject a minted token whose App ID or slug differs from the configured
identity before creating an authorization check.
